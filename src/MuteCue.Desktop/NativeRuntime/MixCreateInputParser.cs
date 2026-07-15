using BeacnMuteOverlay;

namespace MuteCue.Desktop.NativeRuntime;

internal sealed record MixCreateButtonEvent(string Mode, int Position, long CapturedAtUtcTicks);

internal sealed class MixCreateInputParser
{
    private int _pressedAll;
    private int _pressedAudience;
    private int _pressedPage;

    internal long MappingGeneration { get; private set; }
    internal int LastPageDelta { get; private set; }

    internal IReadOnlyList<MixCreateButtonEvent> Process(UsbPacket packet)
    {
        LastPageDelta = 0;
        var data = packet.Data;
        if (packet.Endpoint != 0x83 || data is null || data.Length < 10 ||
            data[0] != 0 || data[1] != 0 || data[2] != 0 || data[3] != 0x06)
        {
            return [];
        }

        var page = data[9] & 0x06;
        if (page == 0)
        {
            _pressedPage = 0;
        }
        else if (page != _pressedPage)
        {
            _pressedPage = page;
            MappingGeneration++;
            LastPageDelta = page == 0x02 ? -1 : page == 0x04 ? 1 : 0;
        }

        var events = new List<MixCreateButtonEvent>(2);
        var all = data[8] & 0x0F;
        if (all == 0)
        {
            _pressedAll = 0;
        }
        else if (all != _pressedAll)
        {
            _pressedAll = all;
            var position = MaskToPosition(all, audience: false);
            if (position >= 0)
            {
                events.Add(new MixCreateButtonEvent("All", position, packet.CapturedAtUtc.Ticks));
            }
        }

        var audience = data[8] & 0xF0;
        if (audience == 0)
        {
            _pressedAudience = 0;
        }
        else if (audience != _pressedAudience)
        {
            _pressedAudience = audience;
            var position = MaskToPosition(audience, audience: true);
            if (position >= 0)
            {
                events.Add(new MixCreateButtonEvent("Audience", position, packet.CapturedAtUtc.Ticks));
            }
        }

        return events;
    }

    private static int MaskToPosition(int mask, bool audience) => audience
        ? mask switch { 0x10 => 0, 0x20 => 1, 0x40 => 2, 0x80 => 3, _ => -1 }
        : mask switch { 0x01 => 0, 0x02 => 1, 0x04 => 2, 0x08 => 3, _ => -1 };
}
