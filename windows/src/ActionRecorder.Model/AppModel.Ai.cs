using System.Collections.ObjectModel;
using ActionRecorder.Core;
using ActionRecorder.Native;

namespace ActionRecorder.Model;

public enum AiState
{
    Unknown,
    Checking,
    Ready,
    NoModel,
    NotRunning,
    Disabled,
}

/// <summary>The optional local AI helper (Ollama on this PC). Nothing here leaves the machine; replies only pass through the strict parsers in the core library.</summary>
public sealed partial class AppModel
{
    private AiAssistant _ai;
    private CancellationTokenSource? _aiCancel;
    private AiState _aiState = AiState.Unknown;
    private string _aiMessage = "";
    private bool _aiBusy;
    private string _aiBusyText = "";
    private string _aiReview = "";
    private double? _aiPullFraction;
    private string _suggestedName = "";

    public AiState AiState
    {
        get => _aiState;
        private set
        {
            if (Set(ref _aiState, value)) RaiseAll(nameof(AiReady), nameof(AiNeedsModel), nameof(AiNeedsOllama));
        }
    }

    public string AiMessage
    {
        get => _aiMessage;
        private set => Set(ref _aiMessage, value);
    }

    public bool AiBusy
    {
        get => _aiBusy;
        private set => Set(ref _aiBusy, value);
    }

    public string AiBusyText
    {
        get => _aiBusyText;
        private set => Set(ref _aiBusyText, value);
    }

    public string AiReview
    {
        get => _aiReview;
        private set { if (Set(ref _aiReview, value)) Raise(nameof(HasAiReview)); }
    }

    public bool HasAiReview => _aiReview.Length > 0;
    public bool AiReady => AiState == AiState.Ready;
    public bool AiNeedsModel => AiState == AiState.NoModel;
    public bool AiNeedsOllama => AiState == AiState.NotRunning;

    /// <summary>0..1 while the recommended model downloads, null when the size is not known yet.</summary>
    public double? AiPullFraction
    {
        get => _aiPullFraction;
        private set => Set(ref _aiPullFraction, value);
    }

    public string SuggestedName
    {
        get => _suggestedName;
        private set => Set(ref _suggestedName, value);
    }

    public MacroDraft? Draft { get; private set; }
    public bool HasDraft => Draft is { Actions.Count: > 0 };

    public string RecommendedModel => OllamaClient.RecommendedModel;
    public string RecommendedModelSize => OllamaClient.RecommendedModelSize;
    public string OllamaDownloadPage => OllamaClient.DownloadPage;

    public void CancelAi()
    {
        _aiCancel?.Cancel();
    }

    private CancellationToken BeginAi(string busyText)
    {
        _aiCancel?.Cancel();
        _aiCancel = new CancellationTokenSource();
        AiBusy = true;
        AiBusyText = busyText;
        return _aiCancel.Token;
    }

    private void EndAi()
    {
        AiBusy = false;
        AiBusyText = "";
        AiPullFraction = null;
    }

    /// <summary>Checks whether Ollama is running and has a model. Call from the UI thread.</summary>
    public async Task RefreshAiStatusAsync()
    {
        if (!_settings.AiEnabled)
        {
            AiState = AiState.Disabled;
            AiMessage = "The AI helper is turned off in Settings.";
            return;
        }
        AiState = AiState.Checking;
        AiMessage = "Looking for the local AI helper…";
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(6));
            var status = await _ai.StatusAsync(timeout.Token);
            AiMessage = status.Message;
            AiState = !status.IsRunning ? AiState.NotRunning : status.HasModel ? AiState.Ready : AiState.NoModel;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            AiState = AiState.NotRunning;
            AiMessage = ex is OperationCanceledException ? "The local AI helper did not answer in time." : ex.Message;
        }
    }

    private async Task<T?> RunAi<T>(string busyText, Func<CancellationToken, Task<T>> work) where T : class
    {
        if (_current == null || AiBusy) return null;
        var token = BeginAi(busyText);
        try
        {
            return await work(token);
        }
        catch (OperationCanceledException)
        {
            Show(NoticeKind.Info, "AI request cancelled.");
            return null;
        }
        catch (AiException ex)
        {
            Show(NoticeKind.Warning, ex.Message);
            await RefreshAiStatusAsync();
            return null;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Show(NoticeKind.Warning, "The AI helper could not finish: " + ex.Message);
            return null;
        }
        finally
        {
            EndAi();
        }
    }

    /// <summary>Asks the model for a short written review of the current macro. The text is shown as advice only.</summary>
    public async Task ReviewWithAiAsync()
    {
        var snapshot = _current?.Clone();
        if (snapshot == null) return;
        var text = await RunAi("Reviewing your macro…", c => _ai.ReviewAsync(snapshot, c));
        if (text != null) AiReview = text.Trim();
    }

    /// <summary>Asks the model for edits. They are checked and listed in the Improve panel; none is applied until chosen.</summary>
    public async Task SuggestEditsWithAiAsync()
    {
        var snapshot = _current?.Clone();
        if (snapshot == null) return;
        var edits = await RunAi("Looking for improvements…", c => _ai.ProposeEditsAsync(snapshot, c));
        if (edits == null || _current == null || _current.Id != snapshot.Id) return;
        foreach (var edit in edits)
        {
            // Never list the same suggestion twice.
            if (Proposals.Any(p => p.Edit.Id == edit.Id)) continue;
            Proposals.Add(new ProposalItem(edit));
        }
        Raise(nameof(HasProposals));
        Show(edits.Count > 0 ? NoticeKind.Info : NoticeKind.Success,
            edits.Count > 0 ? $"The AI helper suggested {edits.Count} change{(edits.Count == 1 ? "" : "s")}. Tick the ones you want, then apply." : "The AI helper found nothing to change.");
    }

    /// <summary>Asks the model for a short name. It is shown for the user to accept; the macro is not renamed automatically.</summary>
    public async Task SuggestNameWithAiAsync()
    {
        var snapshot = _current?.Clone();
        if (snapshot == null) return;
        var name = await RunAi("Thinking of a name…", c => _ai.SuggestNameAsync(snapshot, c));
        if (!string.IsNullOrWhiteSpace(name)) SuggestedName = name!;
    }

    public void AcceptSuggestedName()
    {
        if (SuggestedName.Length == 0) return;
        RenameCurrent(SuggestedName);
        SuggestedName = "";
    }

    public void DismissSuggestedName() => SuggestedName = "";

    /// <summary>Turns a plain-English request into keyboard steps. They are previewed; nothing is added until <see cref="InsertDraft"/>.</summary>
    public async Task DraftWithAiAsync(string request)
    {
        if (string.IsNullOrWhiteSpace(request)) return;
        var draft = await RunAi("Writing steps…", c => _ai.DraftStepsAsync(request.Trim(), c));
        Draft = draft;
        RaiseAll(nameof(Draft), nameof(HasDraft));
        if (draft == null) return;
        if (draft.Unsupported)
        {
            Show(NoticeKind.Info, "That can't be done with the keyboard alone. Record it instead, or ask for keyboard steps.");
        }
        else if (draft.Actions.Count == 0)
        {
            Show(NoticeKind.Info, "The AI helper did not return usable steps. Try describing it differently.");
        }
        else if (draft.SkippedLines > 0)
        {
            Show(NoticeKind.Info, $"Drafted {draft.Actions.Count} steps. {draft.SkippedLines} unusable line(s) were ignored.");
        }
    }

    public bool InsertDraft(Guid? afterId)
    {
        if (Draft is not { Actions.Count: > 0 } draft) return false;
        var ok = InsertActions(draft.Actions, afterId);
        if (ok) DiscardDraft();
        return ok;
    }

    public void DiscardDraft()
    {
        Draft = null;
        RaiseAll(nameof(Draft), nameof(HasDraft));
    }

    /// <summary>Downloads the recommended model through the local Ollama server. Call from the UI thread.</summary>
    public async Task PullRecommendedModelAsync()
    {
        if (AiBusy) return;
        var token = BeginAi($"Downloading {OllamaClient.RecommendedModel} ({OllamaClient.RecommendedModelSize})…");
        try
        {
            using var client = new OllamaClient(_settings.AiEndpoint);
            var progress = new Progress<PullProgress>(p =>
            {
                AiPullFraction = p.Fraction;
                AiBusyText = p.Fraction is double f
                    ? $"Downloading {OllamaClient.RecommendedModel}… {f:P0}"
                    : $"{p.Status}…";
            });
            await client.PullModelAsync(OllamaClient.RecommendedModel, progress, token);
            Show(NoticeKind.Success, "The AI model is ready.");
        }
        catch (OperationCanceledException)
        {
            Show(NoticeKind.Info, "Download cancelled. It can be resumed later.");
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Show(NoticeKind.Error, "The model could not be downloaded: " + ex.Message);
        }
        finally
        {
            EndAi();
        }
        await RefreshAiStatusAsync();
    }
}
