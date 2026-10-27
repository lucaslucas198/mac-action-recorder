using System.Collections.ObjectModel;
using ActionRecorder.Core;

namespace ActionRecorder.Model;

/// <summary>One suggested change in the Improve panel. The user ticks the ones to apply.</summary>
public sealed class ProposalItem : ObservableObject
{
    private bool _selected = true;

    public ProposalItem(MacroEdit edit)
    {
        Edit = edit;
    }

    public MacroEdit Edit { get; }
    public string Title => Edit.Title;
    public string Reason => Edit.Reason;
    public bool FromAi => Edit.Source == EditSource.Ai;
    public string SourceText => FromAi ? "AI suggestion" : "Built-in check";

    public bool IsSelected
    {
        get => _selected;
        set => Set(ref _selected, value);
    }
}

public sealed partial class AppModel
{
    public ObservableCollection<MacroFinding> Findings { get; } = new();
    public ObservableCollection<ProposalItem> Proposals { get; } = new();

    public bool HasFindings => Findings.Count > 0;
    public bool HasProposals => Proposals.Count > 0;
    public int WarningCount => Findings.Count(f => f.Severity == FindingSeverity.Warning);

    private void RefreshFindings()
    {
        Findings.Clear();
        if (_current != null)
        {
            var defaults = CurrentDefaults();
            var screen = _s.Probe.PrimaryScreen();
            foreach (var finding in MacroAnalyzer.Analyze(_current, defaults, _verifyForeground, screen)) Findings.Add(finding);
        }
        RaiseAll(nameof(HasFindings), nameof(WarningCount));
    }

    private void ClearProposals()
    {
        if (Proposals.Count == 0) return;
        Proposals.Clear();
        Raise(nameof(HasProposals));
    }

    /// <summary>Applies the one-click fix attached to a finding.</summary>
    public bool ApplyFix(MacroFinding finding)
    {
        if (finding.Fix is not { } fix || _current == null) return false;
        switch (fix.Kind)
        {
            case FixKind.RemoveMouseMoves:
                return Mutate(r =>
                {
                    var ids = r.Actions.Where(a => a.Kind == ActionKind.Move).Select(a => a.Id).ToHashSet();
                    if (ids.Count == 0) return false;
                    r.DeleteActions(ids);
                    return true;
                });
            case FixKind.CapLongPauses:
            {
                var edit = new MacroEdit("fix-cap", EditSource.Rule, new EditOperation.CapPauses(MacroAnalyzer.LongPause, fix.Seconds),
                    "Shorten long pauses", "");
                return Mutate(r => r.ApplyEdits(new[] { edit }) > 0);
            }
            case FixKind.SetLoopDelay:
                LoopDelay = fix.Seconds;
                RefreshFindings();
                return true;
            case FixKind.EnableForegroundCheck:
                if (_current.TargetApp == null)
                {
                    Show(NoticeKind.Info, "This macro has no recorded target program, so there is nothing to check yet. Record it again with the program in front.");
                    return false;
                }
                VerifyForeground = true;
                return true;
            default:
                return false;
        }
    }

    /// <summary>Fills the Improve panel with the built-in rule-based suggestions.</summary>
    public int PlanImprovements()
    {
        Proposals.Clear();
        if (_current != null)
        {
            foreach (var edit in MacroOptimizer.Plan(_current)) Proposals.Add(new ProposalItem(edit));
        }
        Raise(nameof(HasProposals));
        if (Proposals.Count == 0) Show(NoticeKind.Info, "Nothing to improve. The built-in checks found no changes to suggest.");
        return Proposals.Count;
    }

    /// <summary>Applies every ticked suggestion as one undoable change. Returns how many changed something.</summary>
    public int ApplySelectedProposals()
    {
        var chosen = Proposals.Where(p => p.IsSelected).Select(p => p.Edit).ToList();
        if (chosen.Count == 0 || _current == null) return 0;
        var applied = 0;
        Mutate(r =>
        {
            applied = r.ApplyEdits(chosen);
            return applied > 0;
        });
        Show(applied > 0 ? NoticeKind.Success : NoticeKind.Info,
            applied > 0 ? $"Applied {applied} change{(applied == 1 ? "" : "s")}. You can undo them." : "None of those changes applied anymore.");
        return applied;
    }

    public void SetAllProposals(bool selected)
    {
        foreach (var p in Proposals) p.IsSelected = selected;
    }
}
