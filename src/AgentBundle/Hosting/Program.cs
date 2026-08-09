using ConsoleAppFramework;
using MackySoft.AgentBundle.Hosting.Cli.Common.Startup;
using MackySoft.AgentBundle.Hosting.Composition.Common;
using Microsoft.Extensions.DependencyInjection;

namespace MackySoft.AgentBundle;

internal static class Program
{
    private static async Task<int> Main (string[] args)
    {
        ArgumentNullException.ThrowIfNull(args);

        using var serviceProvider = CreateServiceProvider();
        var app = AgentBundleCommandCatalog.RegisterCommands(ConsoleApp.Create());
        var previousServiceProvider = ConsoleApp.ServiceProvider;
        ConsoleApp.ServiceProvider = serviceProvider;

        try
        {
            await app.RunAsync(args, disposeServiceProvider: false).ConfigureAwait(false);
        }
        finally
        {
            ConsoleApp.ServiceProvider = previousServiceProvider;
        }

        return Environment.ExitCode;
    }

    private static ServiceProvider CreateServiceProvider ()
    {
        var services = new ServiceCollection();
        services.AddAgentBundleServices();
        return services.BuildServiceProvider();
    }
}
