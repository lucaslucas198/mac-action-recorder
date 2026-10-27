namespace ActionRecorder.Core;

/// <summary>Pure editing operations on a recording's action list. The UI calls these, and they are
/// unit-tested independently of WPF.</summary>
public static class RecordingEditing
{
    /// <summary>Deletes the given actions. The delay that preceded each deleted action is added to the
    /// next surviving action, so removing a step never silently shortens the pauses around it.</summary>
    public static void DeleteActions(this Recording recording, ISet<Guid> ids)
    {
        if (ids.Count == 0) return;
        var result = new List<MacroAction>(recording.Actions.Count);
        var carry = 0.0;
        foreach (var action in recording.Actions)
        {
            if (ids.Contains(action.Id))
            {
                carry += action.Delay;
            }
            else
            {
                var kept = action;
                kept.Delay += carry;
                carry = 0;
                result.Add(kept);
            }
        }
        recording.Actions = result;
    }

    /// <summary>Duplicates the selected actions as a block, inserted after the last selected action.
    /// Returns the ids of the new copies.</summary>
    public static List<Guid> DuplicateActions(this Recording recording, ISet<Guid> ids)
    {
        var selected = Enumerable.Range(0, recording.Actions.Count).Where(i => ids.Contains(recording.Actions[i].Id)).ToList();
        if (selected.Count == 0) return new List<Guid>();
        var copies = selected.Select(i => recording.Actions[i].Copy(newId: true)).ToList();
        recording.Actions.InsertRange(selected[^1] + 1, copies);
        return copies.Select(c => c.Id).ToList();
    }

    /// <summary>Moves actions to <paramref name="destination"/> (an index in the original list, before removal).</summary>
    public static void MoveActions(this Recording recording, IEnumerable<int> source, int destination)
    {
        var valid = source.Where(i => i >= 0 && i < recording.Actions.Count).Distinct().OrderBy(i => i).ToList();
        if (valid.Count == 0) return;
        var clamped = Math.Max(0, Math.Min(destination, recording.Actions.Count));
        var moving = valid.Select(i => recording.Actions[i]).ToList();
        var removedBefore = valid.Count(i => i < clamped);
        for (var k = valid.Count - 1; k >= 0; k--)
        {
            recording.Actions.RemoveAt(valid[k]);
        }
        recording.Actions.InsertRange(clamped - removedBefore, moving);
    }

    /// <summary>Moves the selected actions up one position (each swaps with the unselected neighbour above).</summary>
    public static void MoveUp(this Recording recording, ISet<Guid> ids)
    {
        var a = recording.Actions;
        for (var i = 1; i < a.Count; i++)
        {
            if (ids.Contains(a[i].Id) && !ids.Contains(a[i - 1].Id))
            {
                (a[i], a[i - 1]) = (a[i - 1], a[i]);
            }
        }
    }

    /// <summary>Moves the selected actions down one position.</summary>
    public static void MoveDown(this Recording recording, ISet<Guid> ids)
    {
        var a = recording.Actions;
        for (var i = a.Count - 2; i >= 0; i--)
        {
            if (ids.Contains(a[i].Id) && !ids.Contains(a[i + 1].Id))
            {
                (a[i], a[i + 1]) = (a[i + 1], a[i]);
            }
        }
    }

    /// <summary>Inserts a wait after the action with <paramref name="afterId"/>, or at the end when null/unknown.</summary>
    public static Guid InsertWait(this Recording recording, double seconds, Guid? afterId)
    {
        var wait = Act.Wait(seconds);
        var index = afterId is Guid id ? recording.Actions.FindIndex(a => a.Id == id) : -1;
        if (index >= 0) recording.Actions.Insert(index + 1, wait);
        else recording.Actions.Add(wait);
        return wait.Id;
    }

    /// <summary>Inserts a block of actions after the action with <paramref name="afterId"/>, or at the end.</summary>
    public static void InsertActions(this Recording recording, IEnumerable<MacroAction> newActions, Guid? afterId)
    {
        var index = afterId is Guid id ? recording.Actions.FindIndex(a => a.Id == id) : -1;
        if (index >= 0) recording.Actions.InsertRange(index + 1, newActions);
        else recording.Actions.AddRange(newActions);
    }

    /// <summary>Replaces the action that has the same id as <paramref name="action"/>. Returns false if none matches.</summary>
    public static bool ReplaceAction(this Recording recording, MacroAction action)
    {
        var index = recording.Actions.FindIndex(a => a.Id == action.Id);
        if (index < 0) return false;
        recording.Actions[index] = action;
        return true;
    }
}
