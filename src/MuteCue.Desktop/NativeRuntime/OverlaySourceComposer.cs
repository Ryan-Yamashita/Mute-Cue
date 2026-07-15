using BeacnMuteOverlay;
using MuteCue.Desktop.Services;

namespace MuteCue.Desktop.NativeRuntime;

internal static class OverlaySourceComposer
{
    internal static string[] Compose(
        NativeSettingsDocument settings,
        IEnumerable<BeacnFaderState> beacnStates,
        DiscordLocalState discordState,
        bool showPreview)
    {
        var sources = new List<string>();
        if (settings.GetBoolean("ForceShow", false) || showPreview)
        {
            sources.Add("Testing overlay");
        }

        if (settings.GetBoolean("BeacnDirectDetect", true))
        {
            var selectedAll = FaderSourceParser.Parse(settings.GetString("BeacnAllFaderNames", "Mic"));
            var selectedAudience = FaderSourceParser.Parse(settings.GetString("BeacnAudienceFaderNames", "Mic"));
            foreach (var state in beacnStates)
            {
                if (state.AllActionStateKnown && state.AllActionActive && selectedAll.Contains(state.Name, StringComparer.OrdinalIgnoreCase))
                {
                    sources.Add($"BEACN {state.Name}: muted to all");
                }

                if (state.AudienceActionStateKnown && state.AudienceActionActive && selectedAudience.Contains(state.Name, StringComparer.OrdinalIgnoreCase))
                {
                    sources.Add($"BEACN {state.Name}: muted to audience");
                }
            }
        }

        if (settings.GetBoolean("DiscordMicDetect", true) && discordState.MicStateKnown && discordState.MicMuted)
        {
            sources.Add("Discord: mic muted");
        }

        if (settings.GetBoolean("DiscordDeafenDetect", true) && discordState.DeafenStateKnown && discordState.Deafened)
        {
            sources.Add("Discord: deafened");
        }

        return sources.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    }
}
