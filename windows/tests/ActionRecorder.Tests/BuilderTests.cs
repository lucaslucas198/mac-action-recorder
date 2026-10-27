using ActionRecorder.Core;

namespace ActionRecorder.Tests;

public static class BuilderTests
{
    private static readonly RecordingOptions Defaults = new();

    [Test]
    public static void DownUpBecomesOneClickWithDelay()
    {
        var events = new List<RawEvent>
        {
            RawEvent.Down(1.0, 100, 200),
            RawEvent.Up(1.05, 100, 200),
            RawEvent.Down(2.0, 300, 400, MouseButton.Right),
            RawEvent.Up(2.1, 300, 400, MouseButton.Right),
        };
        var actions = RecordingBuilder.Build(events, Defaults);
        Check.Equal(2, actions.Count);
        Check.Equal(ActionKind.Click, actions[0].Kind);
        Check.Equal(0.0, actions[0].Delay);
        Check.Equal(MouseButton.Right, actions[1].Button);
        // gap between end of first click (1.05) and start of second (2.0)
        Check.Near(0.95, actions[1].Delay, 1e-9);
    }

    [Test]
    public static void DoubleAndTripleClicksAreMerged()
    {
        var events = new List<RawEvent>
        {
            RawEvent.Down(1.0, 50, 50, count: 1), RawEvent.Up(1.02, 50, 50, count: 1),
            RawEvent.Down(1.15, 51, 50, count: 2), RawEvent.Up(1.17, 51, 50, count: 2),
            RawEvent.Down(1.3, 50, 51, count: 3), RawEvent.Up(1.32, 50, 51, count: 3),
        };
        var actions = RecordingBuilder.Build(events, Defaults);
        Check.Equal(1, actions.Count);
        Check.Equal(3, actions[0].ClickCount!.Value);
    }

    [Test]
    public static void FarApartClicksStaySeparate()
    {
        var events = new List<RawEvent>
        {
            RawEvent.Down(1.0, 50, 50), RawEvent.Up(1.02, 50, 50),
            RawEvent.Down(1.15, 500, 500, count: 2), RawEvent.Up(1.17, 500, 500, count: 2),
        };
        var actions = RecordingBuilder.Build(events, Defaults);
        Check.Equal(2, actions.Count);
        Check.Equal(2, actions[1].ClickCount!.Value);
    }

    [Test]
    public static void DragIsRecordedAsDownDragUp()
    {
        var events = new List<RawEvent>
        {
            RawEvent.Down(1.0, 10, 10),
            RawEvent.Drag(1.1, 60, 60),
            RawEvent.Up(1.2, 120, 120),
        };
        var actions = RecordingBuilder.Build(events, Defaults);
        Check.SequenceEqual(new[] { ActionKind.MouseDown, ActionKind.Drag, ActionKind.MouseUp }, actions.Select(a => a.Kind));
    }

    [Test]
    public static void ReleaseWithoutPressIsDropped()
    {
        var actions = RecordingBuilder.Build(new List<RawEvent> { RawEvent.Up(1.0, 5, 5) }, Defaults);
        Check.Equal(0, actions.Count);
    }

    [Test]
    public static void HeldButtonIsReleasedAtTheEnd()
    {
        var actions = RecordingBuilder.Build(new List<RawEvent> { RawEvent.Down(1.0, 10, 10), RawEvent.Drag(1.2, 90, 90) }, Defaults);
        Check.Equal(ActionKind.MouseUp, actions[^1].Kind);
        Check.Equal(90.0, actions[^1].X!.Value);
    }

    [Test]
    public static void MouseMovesAreThrottled()
    {
        var events = new List<RawEvent>();
        for (var i = 0; i < 100; i++)
        {
            events.Add(RawEvent.Move(i * 0.001, i, 0)); // 1 ms apart, 1 px apart
        }
        var kept = RecordingBuilder.Build(events, Defaults).Count;
        Check.True(kept < 10, $"expected strong throttling, kept {kept}");
        Check.True(kept >= 1);
    }

    [Test]
    public static void MovesCanBeExcluded()
    {
        var options = new RecordingOptions { IncludeMouseMove = false };
        var events = new List<RawEvent> { RawEvent.Move(0, 0, 0), RawEvent.Move(1, 100, 100), RawEvent.Drag(1.5, 120, 120) };
        Check.Equal(0, RecordingBuilder.Build(events, options).Count);
    }

    [Test]
    public static void ScrollsCoalesce()
    {
        var events = new List<RawEvent>
        {
            RawEvent.Wheel(1.00, 10, 10, 0, -120),
            RawEvent.Wheel(1.02, 10, 10, 0, -120),
            RawEvent.Wheel(1.04, 10, 10, 0, -120),
            RawEvent.Wheel(2.00, 10, 10, 0, 120),
        };
        var actions = RecordingBuilder.Build(events, Defaults);
        Check.Equal(2, actions.Count);
        Check.Equal(-360, actions[0].ScrollY!.Value);
        Check.Equal(120, actions[1].ScrollY!.Value);
    }

    [Test]
    public static void ScrollCanBeExcluded()
    {
        var options = new RecordingOptions { RecordScroll = false };
        Check.Equal(0, RecordingBuilder.Build(new List<RawEvent> { RawEvent.Wheel(1, 1, 1, 0, 120) }, options).Count);
    }

    [Test]
    public static void TypedCharactersBecomeOneTextAction()
    {
        var events = new List<RawEvent>();
        var t = 1.0;
        foreach (var ch in "hello")
        {
            events.Add(RawEvent.KeyPress(t, 0x41, KeyModifiers.None, ch.ToString()));
            events.Add(RawEvent.KeyRelease(t + 0.02, 0x41, KeyModifiers.None));
            t += 0.1;
        }
        var actions = RecordingBuilder.Build(events, Defaults);
        Check.Equal(1, actions.Count);
        Check.Equal("hello", actions[0].Text);
    }

    [Test]
    public static void LongPauseStartsANewTextAction()
    {
        var events = new List<RawEvent>
        {
            RawEvent.KeyPress(1.0, 0x41, KeyModifiers.None, "a"),
            RawEvent.KeyPress(5.0, 0x42, KeyModifiers.None, "b"),
        };
        var actions = RecordingBuilder.Build(events, Defaults);
        Check.Equal(2, actions.Count);
        Check.Near(4.0, actions[1].Delay, 1e-9);
    }

    [Test]
    public static void ShortcutsAndSpecialKeysBecomeKeyActions()
    {
        var events = new List<RawEvent>
        {
            RawEvent.KeyPress(1.0, KeyCodes.K, KeyModifiers.Control, "\u000B"),
            RawEvent.KeyPress(1.5, KeyCodes.Return, KeyModifiers.None, "\r"),
            RawEvent.KeyPress(2.0, KeyCodes.Left, KeyModifiers.Option, ""),
            RawEvent.KeyPress(2.5, KeyCodes.Tab, KeyModifiers.Shift, "\t"),
        };
        var actions = RecordingBuilder.Build(events, Defaults);
        Check.Equal(4, actions.Count);
        Check.True(actions.All(a => a.Kind == ActionKind.Key));
        Check.Equal(KeyModifiers.Control, actions[0].Modifiers!.Value);
        Check.Equal(KeyCodes.Return, actions[1].KeyCode!.Value);
    }

    [Test]
    public static void ShiftedLettersStayText()
    {
        var events = new List<RawEvent> { RawEvent.KeyPress(1.0, 0x41, KeyModifiers.Shift, "A") };
        var actions = RecordingBuilder.Build(events, Defaults);
        Check.Equal(ActionKind.Text, actions[0].Kind);
        Check.Equal("A", actions[0].Text);
    }

    [Test]
    public static void KeyUpsAreIgnored()
    {
        var events = new List<RawEvent> { RawEvent.KeyRelease(1.0, KeyCodes.Return, KeyModifiers.None) };
        Check.Equal(0, RecordingBuilder.Build(events, Defaults).Count);
    }

    [Test]
    public static void TextAndShortcutsCanBeExcluded()
    {
        var events = new List<RawEvent>
        {
            RawEvent.KeyPress(1.0, 0x41, KeyModifiers.None, "a"),
            RawEvent.KeyPress(1.1, KeyCodes.Return, KeyModifiers.None, "\r"),
            RawEvent.KeyPress(1.2, KeyCodes.K, KeyModifiers.Control, "\u000B"),
        };
        Check.Equal(2, RecordingBuilder.Build(events, new RecordingOptions { RecordText = false }).Count);
        Check.Equal(1, RecordingBuilder.Build(events, new RecordingOptions { RecordShortcuts = false }).Count);
    }

    [Test]
    public static void OrderIsPreservedAndDelaysAreNonNegative()
    {
        var events = new List<RawEvent>
        {
            RawEvent.Move(0.0, 0, 0),
            RawEvent.Down(0.5, 100, 100), RawEvent.Up(0.55, 100, 100),
            RawEvent.KeyPress(0.5, 0x41, KeyModifiers.None, "x"), // same timestamp as the click start
            RawEvent.KeyPress(0.9, KeyCodes.Return, KeyModifiers.None, "\r"),
        };
        var actions = RecordingBuilder.Build(events, Defaults);
        Check.SequenceEqual(new[] { ActionKind.Move, ActionKind.Click, ActionKind.Text, ActionKind.Key }, actions.Select(a => a.Kind));
        Check.True(actions.All(a => a.Delay >= 0));
    }

    [Test]
    public static void PositionsAreRounded()
    {
        var actions = RecordingBuilder.Build(new List<RawEvent> { RawEvent.Down(1, 10.126, 20.999), RawEvent.Up(1.01, 10.126, 20.999) }, Defaults);
        Check.Equal(10.13, actions[0].X!.Value);
        Check.Equal(21.0, actions[0].Y!.Value);
    }

    [Test]
    public static void MoveThrottleRequiresTimeAndDistance()
    {
        var throttle = new MoveThrottle(0.05, 5);
        Check.True(throttle.ShouldAccept(0, 0, 0));
        Check.False(throttle.ShouldAccept(0.01, 100, 100));
        Check.False(throttle.ShouldAccept(0.06, 1, 1));
        Check.True(throttle.ShouldAccept(0.06, 50, 50));
        throttle.Reset();
        Check.True(throttle.ShouldAccept(0.07, 50, 50));
    }

    [Test]
    public static void PrintableDetection()
    {
        Check.True(RecordingBuilder.IsPrintable("a"));
        Check.True(RecordingBuilder.IsPrintable("é😀"));
        Check.False(RecordingBuilder.IsPrintable(""));
        Check.False(RecordingBuilder.IsPrintable("\r"));
        Check.False(RecordingBuilder.IsPrintable("\u001b"));
    }
}
