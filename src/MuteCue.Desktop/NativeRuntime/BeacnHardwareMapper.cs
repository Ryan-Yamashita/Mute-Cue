using BeacnMuteOverlay;

namespace MuteCue.Desktop.NativeRuntime;

internal sealed record BeacnHardwareTarget(string Name, bool MappingConfident);

internal sealed class BeacnHardwareMapper
{
    private BeacnFaderState[] _states = [];
    private string _fingerprint = string.Empty;

    internal int CurrentPage { get; private set; }
    internal bool PageKnown { get; private set; }
    internal long MappingGeneration { get; private set; }

    internal void UpdateStates(IEnumerable<BeacnFaderState> states)
    {
        var ordered = states.OrderBy(state => state.Order).ToArray();
        var fingerprint = string.Join('|', ordered.Select(state => $"{state.Order}:{state.Name.Trim().ToUpperInvariant()}:{(state.IsLocked ? 1 : 0)}"));
        if (_fingerprint.Length > 0 && !string.Equals(_fingerprint, fingerprint, StringComparison.Ordinal))
        {
            MappingGeneration++;
            PageKnown = false;
        }

        _fingerprint = fingerprint;
        _states = ordered;
        CurrentPage = Math.Clamp(CurrentPage, 0, GetPageCount() - 1);
    }

    internal void ApplyPageDelta(int delta)
    {
        if (delta == 0)
        {
            return;
        }

        MappingGeneration++;
        CurrentPage = Math.Clamp(CurrentPage + Math.Sign(delta), 0, GetPageCount() - 1);
    }

    internal BeacnHardwareTarget? Resolve(int position, bool stateFresh, bool geometryStable)
    {
        if (position is < 0 or > 3 || _states.Length == 0)
        {
            return null;
        }

        var layout = GetPageNames(CurrentPage);
        if (position >= layout.Names.Length)
        {
            return null;
        }

        var confident = stateFresh && geometryStable && (position < layout.LockedCount || PageKnown);
        return new BeacnHardwareTarget(layout.Names[position], confident);
    }

    internal void ApplyConfirmation(int position, string confirmedName, long mappingGeneration)
    {
        if (mappingGeneration != MappingGeneration || position is < 0 or > 3 || string.IsNullOrWhiteSpace(confirmedName))
        {
            return;
        }

        var ordered = _states.OrderBy(state => state.Order).ToArray();
        var locked = ordered.Where(state => state.IsLocked).Take(3).ToArray();
        if (position < locked.Length)
        {
            return;
        }

        var unlocked = ordered.Where(state => !state.IsLocked).ToArray();
        var pagedSlots = Math.Max(1, 4 - locked.Length);
        var pageOffset = position - locked.Length;
        if (pageOffset is < 0 || pageOffset >= pagedSlots)
        {
            return;
        }

        var sourceIndex = Array.FindIndex(unlocked, state => string.Equals(state.Name.Trim(), confirmedName.Trim(), StringComparison.OrdinalIgnoreCase));
        if (sourceIndex < 0)
        {
            return;
        }

        var pageCount = GetPageCount(unlocked.Length, pagedSlots);
        for (var page = 0; page < pageCount; page++)
        {
            if (GetPagedStartIndex(page, unlocked.Length, pagedSlots) + pageOffset == sourceIndex)
            {
                CurrentPage = page;
                PageKnown = true;
                return;
            }
        }
    }

    private (string[] Names, int LockedCount) GetPageNames(int page)
    {
        var locked = _states.Where(state => state.IsLocked).Take(3).ToArray();
        var unlocked = _states.Where(state => !state.IsLocked).ToArray();
        var pagedSlots = Math.Max(1, 4 - locked.Length);
        var pageCount = GetPageCount(unlocked.Length, pagedSlots);
        var clampedPage = Math.Clamp(page, 0, pageCount - 1);
        var start = GetPagedStartIndex(clampedPage, unlocked.Length, pagedSlots);
        var names = locked.Select(state => state.Name.Trim())
            .Concat(unlocked.Skip(start).Take(pagedSlots).Select(state => state.Name.Trim()))
            .Where(name => name.Length > 0)
            .ToArray();
        return (names, locked.Length);
    }

    private int GetPageCount()
    {
        var lockedCount = Math.Min(3, _states.Count(state => state.IsLocked));
        var unlockedCount = _states.Count(state => !state.IsLocked);
        return GetPageCount(unlockedCount, Math.Max(1, 4 - lockedCount));
    }

    private static int GetPageCount(int sourceCount, int pagedSlots) => Math.Max(1, (int)Math.Ceiling(sourceCount / (double)pagedSlots));

    private static int GetPagedStartIndex(int page, int sourceCount, int pagedSlots)
    {
        if (sourceCount <= 0 || pagedSlots <= 0)
        {
            return 0;
        }

        var maximumStart = Math.Max(0, sourceCount - pagedSlots);
        var nominalStart = Math.Max(0, page) * pagedSlots;
        return Math.Min(nominalStart, maximumStart);
    }
}
