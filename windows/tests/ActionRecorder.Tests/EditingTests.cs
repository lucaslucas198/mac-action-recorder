using ActionRecorder.Core;

namespace ActionRecorder.Tests;

public static class EditingTests
{
    private static Recording Make(params MacroAction[] actions)
    {
        var r = new Recording("t");
        r.Actions.AddRange(actions);
        return r;
    }

    [Test]
    public static void DeleteCarriesTheDelayForward()
    {
        var a = Act.Click(1, 1, delay: 0.5);
        var b = Act.Click(2, 2, delay: 1.0);
        var c = Act.Click(3, 3, delay: 2.0);
        var r = Make(a, b, c);
        r.DeleteActions(new HashSet<Guid> { b.Id });
        Check.Equal(2, r.Actions.Count);
        Check.Near(3.0, r.Actions[1].Delay);
        Check.Near(3.5, r.OriginalDuration);
    }

    [Test]
    public static void DeleteLastDropsItsDelay()
    {
        var a = Act.Click(1, 1, delay: 0.5);
        var b = Act.Click(2, 2, delay: 1.0);
        var r = Make(a, b);
        r.DeleteActions(new HashSet<Guid> { b.Id });
        Check.Equal(1, r.Actions.Count);
        Check.Near(0.5, r.OriginalDuration);
    }

    [Test]
    public static void DeleteEverythingAndNothing()
    {
        var a = Act.Click(1, 1);
        var r = Make(a);
        r.DeleteActions(new HashSet<Guid>());
        Check.Equal(1, r.Actions.Count);
        r.DeleteActions(new HashSet<Guid> { a.Id });
        Check.Equal(0, r.Actions.Count);
    }

    [Test]
    public static void DuplicateInsertsCopiesWithNewIds()
    {
        var a = Act.Text("a");
        var b = Act.Text("b");
        var c = Act.Text("c");
        var r = Make(a, b, c);
        var ids = r.DuplicateActions(new HashSet<Guid> { a.Id, b.Id });
        Check.Equal(2, ids.Count);
        Check.SequenceEqual(new[] { "a", "b", "a", "b", "c" }, r.Actions.Select(x => x.Text!));
        Check.Equal(5, r.Actions.Select(x => x.Id).Distinct().Count());
        Check.Equal(0, r.DuplicateActions(new HashSet<Guid> { Guid.NewGuid() }).Count);
    }

    [Test]
    public static void MoveActionsFollowsListSemantics()
    {
        var r = Make(Act.Text("a"), Act.Text("b"), Act.Text("c"), Act.Text("d"));
        r.MoveActions(new[] { 0 }, 3); // move "a" to just before "d"
        Check.SequenceEqual(new[] { "b", "c", "a", "d" }, r.Actions.Select(x => x.Text!));
        r.MoveActions(new[] { 3 }, 0); // "d" to the front
        Check.SequenceEqual(new[] { "d", "b", "c", "a" }, r.Actions.Select(x => x.Text!));
        r.MoveActions(new[] { 0, 1 }, 4); // two to the end
        Check.SequenceEqual(new[] { "c", "a", "d", "b" }, r.Actions.Select(x => x.Text!));
        r.MoveActions(new[] { 99, -1 }, 0); // invalid indices ignored
        Check.Equal(4, r.Actions.Count);
    }

    [Test]
    public static void MoveUpAndDown()
    {
        var a = Act.Text("a"); var b = Act.Text("b"); var c = Act.Text("c");
        var r = Make(a, b, c);
        r.MoveUp(new HashSet<Guid> { c.Id });
        Check.SequenceEqual(new[] { "a", "c", "b" }, r.Actions.Select(x => x.Text!));
        r.MoveUp(new HashSet<Guid> { c.Id });
        r.MoveUp(new HashSet<Guid> { c.Id });
        Check.SequenceEqual(new[] { "c", "a", "b" }, r.Actions.Select(x => x.Text!));
        r.MoveDown(new HashSet<Guid> { c.Id });
        Check.SequenceEqual(new[] { "a", "c", "b" }, r.Actions.Select(x => x.Text!));
        r.MoveDown(new HashSet<Guid> { b.Id });
        Check.SequenceEqual(new[] { "a", "c", "b" }, r.Actions.Select(x => x.Text!));
    }

    [Test]
    public static void InsertWaitAndActions()
    {
        var a = Act.Text("a"); var b = Act.Text("b");
        var r = Make(a, b);
        var waitId = r.InsertWait(1.5, a.Id);
        Check.Equal(waitId, r.Actions[1].Id);
        r.InsertWait(2, null);
        Check.Equal(ActionKind.Wait, r.Actions[^1].Kind);
        r.InsertActions(new[] { Act.Text("x") }, b.Id);
        Check.Equal("x", r.Actions[3].Text);
        r.InsertActions(new[] { Act.Text("y") }, Guid.NewGuid());
        Check.Equal("y", r.Actions[^1].Text);
    }

    [Test]
    public static void ReplaceAction()
    {
        var a = Act.Text("a");
        var r = Make(a);
        var edited = a with { Text = "changed" };
        Check.True(r.ReplaceAction(edited));
        Check.Equal("changed", r.Actions[0].Text);
        Check.False(r.ReplaceAction(Act.Text("zzz")));
    }

    [Test]
    public static void CloneSharesNothing()
    {
        var r = Make(Act.Text("a"));
        var copy = r.Clone();
        copy.Actions[0].Text = "changed";
        copy.Name = "other";
        Check.Equal("a", r.Actions[0].Text);
        Check.Equal("t", r.Name);
    }
}
