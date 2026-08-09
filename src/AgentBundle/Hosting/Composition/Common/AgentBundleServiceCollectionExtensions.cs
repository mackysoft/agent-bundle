using MackySoft.AgentDistribution.Hosting.Composition;
using MackySoft.FileSystem;
using Microsoft.Extensions.DependencyInjection;

namespace MackySoft.AgentBundle.Hosting.Composition.Common;

internal static class AgentBundleServiceCollectionExtensions
{
    public static IServiceCollection AddAgentBundleServices (this IServiceCollection services)
    {
        ArgumentNullException.ThrowIfNull(services);

        services.AddAgentDistributionCommandRuntime(options =>
        {
            options.ProductName = "AgentBundle";
            options.PackageBaseDirectory = AbsolutePath.Parse(AppContext.BaseDirectory);
        });
        return services;
    }
}
