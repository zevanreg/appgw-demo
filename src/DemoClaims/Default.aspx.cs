using System;
using System.Configuration;
using System.Data;
using System.Data.Common;
using System.Linq;
using System.Security.Claims;
using System.Threading;
using System.Web;
using System.Web.UI;
using System.Web.UI.WebControls;
using Azure.Core;
using Azure.Identity;
using Microsoft.Data.SqlClient;

namespace DemoClaims
{
    public partial class _Default : Page
    {
        private const string MicrosoftDataSqlClientConnectionStringName = "AzureSqlDatabaseMicrosoftDataSqlClient";
        private const string SystemDataSqlClientConnectionStringName = "AzureSqlDatabaseSystemDataSqlClient";
        private const string AzureSqlScope = "https://database.windows.net/.default";
        private const string AzureClientIdEnvironmentVariable = "AZURE_CLIENT_ID";
        private const string ObjectGuidClaimType = "onprem_objectguid";
        private static readonly TokenCredential AzureSqlCredential =
            CreateAzureSqlCredential();
        private static readonly TokenRequestContext AzureSqlTokenRequest =
            new TokenRequestContext(new[] { AzureSqlScope });

        protected void Page_Load(object sender, EventArgs e)
        {
            DisplayClaims();
        }

        private void DisplayClaims()
        {
            var principal = Context.User as ClaimsPrincipal;

            if (principal == null)
            {
                AuthenticationStatus.Text = "The current request does not contain a claims-based identity.";
                ClaimsGrid.Visible = false;
                ResetUserLookups("The Azure SQL user lookup was skipped because no claims-based identity is available.");
                return;
            }

            var claims = principal.Identities
                .SelectMany(claimsIdentity => claimsIdentity.Claims.Select(claim => new
                {
                    AuthenticationType = claimsIdentity.AuthenticationType ?? String.Empty,
                    claim.Type,
                    Value = FormatClaimValue(claim),
                    claim.ValueType,
                    claim.Issuer,
                    claim.OriginalIssuer
                }))
                .ToList();

            var identity = principal.Identity;
            if (identity != null && identity.IsAuthenticated)
            {
                var displayName = String.IsNullOrWhiteSpace(identity.Name)
                    ? "(name not provided)"
                    : HttpUtility.HtmlEncode(identity.Name);

                AuthenticationStatus.Text = String.Format(
                    "Authenticated as <strong>{0}</strong>. {1} claim{2} found.",
                    displayName,
                    claims.Count,
                    claims.Count == 1 ? String.Empty : "s");
            }
            else
            {
                AuthenticationStatus.Text = "The current request is not authenticated.";
            }

            ClaimsGrid.DataSource = claims;
            ClaimsGrid.DataBind();

            DisplayDatabaseUser(principal);
        }

        private static string FormatClaimValue(Claim claim)
        {
            if (!IsObjectGuidClaim(claim))
            {
                return claim.Value;
            }

            Guid objectGuid;
            return TryParseObjectGuid(claim.Value, out objectGuid)
                ? objectGuid.ToString()
                : claim.Value;
        }

        private void DisplayDatabaseUser(ClaimsPrincipal principal)
        {
            if (principal.Identity == null || !principal.Identity.IsAuthenticated)
            {
                ResetUserLookups("The Azure SQL user lookup was skipped because the current request is not authenticated.");
                return;
            }

            var objectGuidClaim = principal.Claims.FirstOrDefault(IsObjectGuidClaim);
            if (objectGuidClaim == null)
            {
                ResetUserLookups("The current identity does not contain an onprem_objectguid claim.");
                return;
            }

            Guid objectGuid;
            if (!TryParseObjectGuid(objectGuidClaim.Value, out objectGuid))
            {
                ResetUserLookups("The onprem_objectguid claim is not a valid GUID.");
                return;
            }

            DisplayDatabaseUserResult(
                "Microsoft.Data.SqlClient",
                MicrosoftDataSqlClientConnectionStringName,
                MicrosoftDataSqlClientStatus,
                MicrosoftDataSqlClientGrid,
                objectGuid,
                connectionString => GetDatabaseUserWithMicrosoftDataSqlClient(
                    objectGuid,
                    connectionString));

            DisplayDatabaseUserResult(
                "System.Data.SqlClient",
                SystemDataSqlClientConnectionStringName,
                SystemDataSqlClientStatus,
                SystemDataSqlClientGrid,
                objectGuid,
                connectionString => GetDatabaseUserWithSystemDataSqlClient(
                    objectGuid,
                    connectionString));
        }

        private void DisplayDatabaseUserResult(
            string connectionMethod,
            string connectionStringName,
            Literal statusControl,
            GridView grid,
            Guid objectGuid,
            Func<string, DataTable> getUser)
        {
            try
            {
                var connectionString = GetAzureSqlConnectionString(connectionStringName);
                if (String.IsNullOrWhiteSpace(connectionString))
                {
                    ResetUserLookup(statusControl, grid, String.Format(
                        "The Azure SQL connection string '{0}' is not configured.",
                        HttpUtility.HtmlEncode(connectionStringName)));
                    return;
                }

                var user = getUser(connectionString);

                if (user.Rows.Count == 0)
                {
                    ResetUserLookup(statusControl, grid, String.Format(
                        "No database user was found for object GUID <code>{0}</code>.",
                        HttpUtility.HtmlEncode(objectGuid.ToString())));
                    return;
                }

                statusControl.Text = String.Format(
                    "Database user found for object GUID <code>{0}</code>.",
                    HttpUtility.HtmlEncode(objectGuid.ToString()));
                grid.DataSource = user;
                grid.DataBind();
                grid.Visible = true;
            }
            catch (DbException exception)
            {
                ReportUserLookupError(connectionMethod, statusControl, grid, exception);
            }
            catch (AuthenticationFailedException exception)
            {
                ReportUserLookupError(connectionMethod, statusControl, grid, exception);
            }
            catch (InvalidOperationException exception)
            {
                ReportUserLookupError(connectionMethod, statusControl, grid, exception);
            }
            catch (ArgumentException exception)
            {
                ReportUserLookupError(connectionMethod, statusControl, grid, exception);
            }
        }

        private static DataTable GetDatabaseUserWithMicrosoftDataSqlClient(
            Guid objectGuid,
            string connectionString)
        {
            var user = new DataTable();
            var sqlConnectionString = ApplyLegacySqlClientDefaults(connectionString);

            using (var connection = new SqlConnection(sqlConnectionString))
            using (var command = new SqlCommand(
                "SELECT TOP (1) * FROM [dbo].[Users] WHERE [objectguid] = @ObjectGuid;",
                connection))
            {
                command.Parameters.Add("@ObjectGuid", SqlDbType.UniqueIdentifier).Value = objectGuid;

                connection.Open();
                using (var reader = command.ExecuteReader(CommandBehavior.SingleRow))
                {
                    user.Load(reader);
                }
            }

            return user;
        }

        private static DataTable GetDatabaseUserWithSystemDataSqlClient(
            Guid objectGuid,
            string connectionString)
        {
            var accessToken = AzureSqlCredential.GetToken(
                AzureSqlTokenRequest,
                CancellationToken.None);
            var user = new DataTable();
            using (var connection =
                new System.Data.SqlClient.SqlConnection(connectionString))
            using (var command = new System.Data.SqlClient.SqlCommand(
                "SELECT TOP (1) * FROM [dbo].[Users] WHERE [objectguid] = @ObjectGuid;",
                connection))
            {
                connection.AccessToken = accessToken.Token;
                command.Parameters.Add("@ObjectGuid", SqlDbType.UniqueIdentifier).Value = objectGuid;

                connection.Open();
                using (var reader = command.ExecuteReader(CommandBehavior.SingleRow))
                {
                    user.Load(reader);
                }
            }

            return user;
        }

        private void ResetUserLookups(string status)
        {
            ResetUserLookup(
                MicrosoftDataSqlClientStatus,
                MicrosoftDataSqlClientGrid,
                status);
            ResetUserLookup(
                SystemDataSqlClientStatus,
                SystemDataSqlClientGrid,
                status);
        }

        private static void ResetUserLookup(
            Literal statusControl,
            GridView grid,
            string status)
        {
            statusControl.Text = status;
            grid.DataSource = null;
            grid.DataBind();
            grid.Visible = false;
        }

        private static void ReportUserLookupError(
            string connectionMethod,
            Literal statusControl,
            GridView grid,
            Exception exception)
        {
            System.Diagnostics.Trace.TraceError(
                "The database user lookup using {0} failed: {1}",
                connectionMethod,
                exception);
            ResetUserLookup(
                statusControl,
                grid,
                "The database user lookup failed. Review the application logs and Azure SQL configuration.");
        }

        private static string GetAzureSqlConnectionString(string connectionStringName)
        {
            var configuredConnection =
                ConfigurationManager.ConnectionStrings[connectionStringName];

            if (configuredConnection != null &&
                !String.IsNullOrWhiteSpace(configuredConnection.ConnectionString))
            {
                return configuredConnection.ConnectionString;
            }

            return Environment.GetEnvironmentVariable(
                "SQLAZURECONNSTR_" + connectionStringName);
        }

        private static TokenCredential CreateAzureSqlCredential()
        {
            var clientId = Environment.GetEnvironmentVariable(
                AzureClientIdEnvironmentVariable);

            return String.IsNullOrWhiteSpace(clientId)
                ? new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned)
                : new ManagedIdentityCredential(
                    ManagedIdentityId.FromUserAssignedClientId(clientId));
        }

        private static string ApplyLegacySqlClientDefaults(string connectionString)
        {
            var connectionStringBuilder = new SqlConnectionStringBuilder(connectionString);
            if (connectionStringBuilder.ShouldSerialize("Encrypt"))
            {
                return connectionString;
            }

            connectionStringBuilder.Encrypt = SqlConnectionEncryptOption.Optional;
            return connectionStringBuilder.ConnectionString;
        }

        private static bool IsObjectGuidClaim(Claim claim)
        {
            return claim != null &&
                (String.Equals(
                    claim.Type,
                    ObjectGuidClaimType,
                    StringComparison.OrdinalIgnoreCase) ||
                 claim.Type.EndsWith(
                    "/" + ObjectGuidClaimType,
                    StringComparison.OrdinalIgnoreCase));
        }

        private static bool TryParseObjectGuid(string value, out Guid objectGuid)
        {
            if (Guid.TryParse(value, out objectGuid))
            {
                return true;
            }

            try
            {
                var guidBytes = Convert.FromBase64String(value);
                if (guidBytes.Length == 16)
                {
                    objectGuid = new Guid(guidBytes);
                    return true;
                }
            }
            catch (FormatException)
            {
            }

            objectGuid = Guid.Empty;
            return false;
        }
    }
}