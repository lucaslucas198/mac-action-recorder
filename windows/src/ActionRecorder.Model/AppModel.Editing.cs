using ActionRecorder.Core;

namespace ActionRecorder.Model;

/// <summary>A numbered click position for the "Show clicks" overlay.</summary>
public sealed record ClickMarker(int Number, double X, double Y, MouseButton Button, int ActionIndex);

public sealed partial class AppModel
{
    private const int MaxUndo = 60;
    private readonly List<Recording> _undo = new();
    private readonly List<Recording> _redo = new();

    private RelayCommand? _undoCommand;
    private RelayCommand? _redoCommand;
    public RelayCommand UndoCommand => _undoCommand ??= new RelayCommand(Undo, () => CanUndo);
    public RelayCommand RedoCommand => _redoCommand ??= new RelayCommand(Redo, () => CanRedo);

    public bool CanUndo => CanEdit && _undo.Count > 0;
    public bool CanRedo => CanEdit && _redo.Count > 0;

    private void PushUndo()
    {
        if (_current == null) return;
        _undo.Add(_current.Clone());
        if (_undo.Count > MaxUndo) _undo.RemoveAt(0);
        _redo.Clear();
    }

    /// <summary>Runs one undoable change to the current recording and refreshes everything that depends on it.</summary>
    private bool Mutate(Func<Recording, bool> change)
    {
        if (!CanEdit || _current == null) return false;
        PushUndo();
        var before = _undo[^1];
        bool changed;
        try
        {
            changed = change(_current);
        }
        catch (Exception)
        {
            Restore(before);
            _undo.RemoveAt(_undo.Count - 1);
            throw;
        }
        if (!changed)
        {
            _undo.RemoveAt(_undo.Count - 1);
            return false;
        }
        AfterEdit();
        return true;
    }

    private void AfterEdit()
    {
        RebuildRows();
        MarkChanged();
        RefreshFindings();
        ClearProposals();
    }

    private void Restore(Recording snapshot)
    {
        if (_current == null) return;
        _current.Name = snapshot.Name;
        _current.Notes = snapshot.Notes;
        _current.PlaybackDefaults = snapshot.PlaybackDefaults;
        _current.TargetApp = snapshot.TargetApp;
        _current.Actions = snapshot.Actions.Select(a => a.Copy()).ToList();
    }

    public void Undo()
    {
        if (!CanUndo || _current == null) return;
        _redo.Add(_current.Clone());
        var snapshot = _undo[^1];
        _undo.RemoveAt(_undo.Count - 1);
        Restore(snapshot);
        AfterEdit();
    }

    public void Redo()
    {
        if (!CanRedo || _current == null) return;
        _undo.Add(_current.Clone());
        var snapshot = _redo[^1];
        _redo.RemoveAt(_redo.Count - 1);
        Restore(snapshot);
        AfterEdit();
    }

    // ------------------------------------------------------------------ editing actions

    public bool DeleteActions(IReadOnlyCollection<Guid> ids)
    {
        if (ids.Count == 0) return false;
        var set = new HashSet<Guid>(ids);
        return Mutate(r =>
        {
            var before = r.Actions.Count;
            r.DeleteActions(set);
            return r.Actions.Count != before;
        });
    }

    /// <summary>Duplicates the actions and returns the ids of the new copies.</summary>
    public List<Guid> DuplicateActions(IReadOnlyCollection<Guid> ids)
    {
        var created = new List<Guid>();
        if (ids.Count == 0) return created;
        var set = new HashSet<Guid>(ids);
        Mutate(r =>
        {
            created = r.DuplicateActions(set);
            return created.Count > 0;
        });
        return created;
    }

    public bool MoveUp(IReadOnlyCollection<Guid> ids) =>
        ids.Count > 0 && Mutate(r =>
        {
            var before = r.Actions.Select(a => a.Id).ToList();
            r.MoveUp(new HashSet<Guid>(ids));
            return !before.SequenceEqual(r.Actions.Select(a => a.Id));
        });

    public bool MoveDown(IReadOnlyCollection<Guid> ids) =>
        ids.Count > 0 && Mutate(r =>
        {
            var before = r.Actions.Select(a => a.Id).ToList();
            r.MoveDown(new HashSet<Guid>(ids));
            return !before.SequenceEqual(r.Actions.Select(a => a.Id));
        });

    /// <summary>Moves the actions at the given positions so they land at <paramref name="destination"/> (a position in the current list).</summary>
    public bool MoveActions(IReadOnlyCollection<int> sourceIndices, int destination) =>
        sourceIndices.Count > 0 && Mutate(r =>
        {
            var before = r.Actions.Select(a => a.Id).ToList();
            r.MoveActions(sourceIndices, destination);
            return !before.SequenceEqual(r.Actions.Select(a => a.Id));
        });

    public Guid? InsertWait(double seconds, Guid? afterId)
    {
        Guid? id = null;
        var clamped = Num.Clamp(double.IsFinite(seconds) ? seconds : 1, 0, RecordingValidator.MaxDelay);
        Mutate(r =>
        {
            id = r.InsertWait(clamped, afterId);
            return true;
        });
        return id;
    }

    public bool InsertActions(IEnumerable<MacroAction> actions, Guid? afterId)
    {
        var list = actions.Select(a => a.Copy(newId: true)).ToList();
        if (list.Count == 0) return false;
        return Mutate(r =>
        {
            r.InsertActions(list, afterId);
            return true;
        });
    }

    /// <summary>Inserts one of the built-in keyboard presets (see <see cref="Presets"/>).</summary>
    public bool InsertPreset(string presetId, string input, string secondInput, Guid? afterId)
    {
        var actions = Presets.Actions(presetId, input, secondInput);
        return InsertActions(actions, afterId);
    }

    /// <summary>Replaces an action with an edited copy. The change is rejected, and nothing is touched, if the result is not valid.</summary>
    public bool TryUpdateAction(MacroAction edited, out string? error)
    {
        error = null;
        if (!CanEdit || _current == null)
        {
            error = "Editing is not available right now.";
            return false;
        }
        var issues = RecordingValidator.Errors(RecordingValidator.Validate(edited));
        if (issues.Count > 0)
        {
            error = issues[0].Message;
            return false;
        }
        var ok = Mutate(r => r.ReplaceAction(edited));
        if (!ok) error = "That action no longer exists.";
        return ok;
    }

    /// <summary>Edits a copy of the action with <paramref name="change"/>, then applies it if valid.</summary>
    public bool EditAction(Guid id, Action<MacroAction> change, out string? error)
    {
        error = null;
        var existing = _current?.Actions.FirstOrDefault(a => a.Id == id);
        if (existing == null)
        {
            error = "That action no longer exists.";
            return false;
        }
        var copy = existing.Copy();
        change(copy);
        return TryUpdateAction(copy, out error);
    }

    /// <summary>Positions of every click in the current recording, numbered in order, for the overlay.</summary>
    public IReadOnlyList<ClickMarker> ClickMarkers()
    {
        var list = new List<ClickMarker>();
        if (_current == null) return list;
        var number = 0;
        for (var i = 0; i < _current.Actions.Count; i++)
        {
            var a = _current.Actions[i];
            if ((a.Kind == ActionKind.Click || a.Kind == ActionKind.MouseDown) && a.X is double x && a.Y is double y)
            {
                list.Add(new ClickMarker(++number, x, y, a.Button ?? MouseButton.Left, i));
            }
        }
        return list;
    }
}
