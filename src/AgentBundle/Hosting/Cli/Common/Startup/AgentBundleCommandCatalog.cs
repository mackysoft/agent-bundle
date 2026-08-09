using ConsoleAppFramework;
using MackySoft.AgentDistribution.ConsoleAppFramework;

namespace MackySoft.AgentBundle.Hosting.Cli.Common.Startup;

internal static class AgentBundleCommandCatalog
{
    public static ConsoleApp.ConsoleAppBuilder RegisterCommands (ConsoleApp.ConsoleAppBuilder app)
    {
        ArgumentNullException.ThrowIfNull(app);

        return app.RegisterAgentDistributionCommands();
    }
}
