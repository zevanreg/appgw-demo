# Azure Portal setup: Application Gateway, App Service, and SQL

This guide uses the [Azure Portal](https://portal.azure.com) to make Application Gateway's public IP the application entry point, with workload-local private endpoints following the supplied FrameworkReporting_v4 diagram:

```text
Internet client
   -> HTTP port 80 -> Application Gateway WAF_v2 public IP
   -> HTTPS -> Windows App Service private endpoint in the web workload subnet

Windows App Service
   -> outbound VNet integration in a separate delegated subnet
   -> Azure SQL Database private endpoint in the SQL workload subnet
       (authentication uses a user-assigned managed identity)
```

**Important boundaries**

- Application Gateway has a public IP, an **HTTP listener on port 80**, and a regional WAF policy. Browse directly to the public IP; a DNS name is optional. The diagram's external Imperva WAF, if retained, requires separate upstream configuration and source restrictions; it is outside this guide.
- The Windows app accepts inbound application traffic only from the gateway subnet. SQL has no public access; database permissions, not an app-only SQL NSG rule, limit the app identity to data read/write.
- Private endpoints reside in their respective **nondelegated workload subnets**, not a dedicated, centralized private-endpoint subnet. App Service's delegated outbound-integration subnet remains separate and cannot host private endpoints.
- **No frontend TLS, listener certificate, PFX, or custom domain is required.** The gateway-to-App Service connection still uses HTTPS with the platform-provided certificate; you do not upload or manage that certificate. SQL connections remain encrypted.
- **HTTP is for non-sensitive demo traffic only.** Client-to-gateway traffic is unencrypted. Do not send credentials, authentication cookies, personal information, or production data over this path; WAF does not encrypt traffic.
- The Logic App, storage, domain controller, Bastion, and Entra Connect setup are outside this guide. If they already exist, leave them unchanged.
- This guide intentionally differs from the current [infrastructure templates](infra/resources.bicep). Only this document is updated; Bicep, scripts, and deployed resources are unchanged. Do not deploy those templates expecting this topology. For existing resources, treat each **Create** step as **open and verify/update** and plan endpoint relocation separately. Later template deployments can overwrite portal changes.

Portal labels can vary slightly. Use the resource menu's search box if a setting is not under the heading shown.

## Setup order

1. [Prepare names, permissions, and the configuration worksheet](#1-prerequisites-and-worksheet).
2. [Configure networking, private DNS, access rules, and a gateway public IP](#2-networking-and-access-rules).
3. [Create the private Windows App Service](#3-windows-app-service).
4. [Create private Azure SQL and grant database access](#4-azure-sql-database-and-app-connection).
5. [Create the gateway WAF policy and Application Gateway](#5-application-gateway).
6. [Enable diagnostics](#6-diagnostics).
7. [Verify the full path and rejected bypass paths](#7-acceptance-checks-and-troubleshooting).

Reserve the gateway public IP before creating the HTTP listener in step 5. Public DNS and a listener certificate are not prerequisites.

## 1. Prerequisites and worksheet

### Permissions and access

- Use one Azure subscription and its Microsoft Entra tenant. Choose a supported region for all regional resources; private DNS zones are global resources.
- Use a demo app that can serve non-sensitive content without sign-in or an HTTP-to-HTTPS redirect on the public path. No public domain ownership or certificate is needed.
- Your provisioning account needs permission to create/manage the resources, associate the managed identity, and configure the SQL Entra administrator and Entra-only authentication. Resource creation permission does not automatically grant database access. `SQL Server Contributor` alone cannot enable Entra-only authentication; use an appropriately scoped role such as `SQL Security Manager` where needed.
- Select an existing Entra administrator **group**, preferably, or user for SQL. Your database setup account must be that administrator or an authorized group member. **Do not make the web app identity the SQL administrator.**
- Have a workstation with private connectivity and DNS resolution into the VNet for SQL setup and negative private-access tests: for example, a VPN-connected administrative workstation or an existing administrative VM. An ordinary Internet browser or default Cloud Shell session does not acquire VNet access merely because you opened Azure Portal. Do not use the demo domain controller as a general-purpose application/deployment workstation.
- If a provider is unregistered, use **Subscriptions > your subscription > Resource providers** to register the required provider: `Microsoft.Network`, `Microsoft.Web`, `Microsoft.Sql`, `Microsoft.ManagedIdentity`, and `Microsoft.OperationalInsights`.
- Review pricing and quotas. Application Gateway, the S1 plan, SQL Basic, private endpoints, public IPs, and log ingestion incur charges. This guide does not validate your region's availability or subscription quota.

### Example names

For a new manual deployment, use these names or your own naming convention. Replace `<suffix>` with a globally unique lowercase suffix. For existing resources, use their actual names instead.

| Resource | Example name |
| --- | --- |
| Resource group / VNet | `rg-ingress-demo` / `vnet-ingress-demo` |
| Gateway subnet / web integration subnet | `snet-appgateway` / `snet-web-integration` |
| Web workload subnet / SQL workload subnet | Existing workload subnets from the diagram; record actual names below |
| Gateway NSG / web workload NSG | `nsg-appgateway` / existing web workload NSG (or `nsg-web-workload`) |
| Web endpoint application security group (ASG) | `asg-webapp-private-endpoint` |
| Gateway public IP / DNS label | `pip-appgateway` / `agw-<suffix>` |
| Windows App Service plan / web app | `asp-webapp` / `web-<suffix>` |
| Web app user-assigned managed identity | `mi-webapp-sql` |
| SQL logical server / database | `sql-<suffix>` / `appdb` |
| Application Gateway / regional WAF policy | `agw-ingress-demo` / `waf-appgateway` |
| Web / SQL private endpoints | `pe-webapp` / `pe-sql` |
| Log Analytics workspace | `law-ingress-demo` |

Create the resource group under **Resource groups > Create**, or reuse your existing group. Do not rename an existing azd environment or move its resources as part of this walkthrough.

### Values to copy as you proceed

Replace the angle-bracket placeholders later in this guide with the following **actual values**. Never infer a generated hostname from a resource name.

| Placeholder | Where to obtain it |
| --- | --- |
| `<APP_HOST>` | Web app **Overview > Default domain** |
| `<SCM_HOST>` | Web private endpoint **DNS configuration**, SCM entry |
| `<AGW_FQDN>` | Optional gateway public IP **Overview > DNS name**, if a DNS label is configured |
| `<AGW_PUBLIC_IP>` | Gateway public IP **Overview > IP address** |
| `<GATEWAY_SUBNET_CIDR>` | Actual gateway subnet address range |
| `<WEB_WORKLOAD_SUBNET>` | Nondelegated web workload subnet containing the inbound web private endpoint, beside the web integration subnet in the diagram |
| `<SQL_WORKLOAD_SUBNET>` | Nondelegated SQL/data workload subnet containing the SQL private endpoint in the diagram |
| `<WEB_INTEGRATION_SUBNET>` | Separate web outbound-integration subnet delegated to `Microsoft.Web/serverFarms` |
| `<SQL_FQDN>` | SQL logical server **Overview > Server name**, including `.database.windows.net` in Azure public cloud |
| `<IDENTITY_NAME>` | Managed identity resource name, for example `mi-webapp-sql` |
| `<MI_CLIENT_ID>` | Managed identity **Overview/Properties > Client ID** |
| `<MI_OBJECT_ID>` | Managed identity **Overview/Properties > Principal ID / Object ID**, not its client ID |

For existing resources, the outputs documented in [README.md](README.md#provision) can help identify app, gateway, SQL, and identity values. Verify them in the portal; the templates' ingress and subnet layout are not the target of this guide.

## 2. Networking and access rules

### 2.1 Create or reuse the VNet and subnets

1. Open **Virtual networks** and select the existing application VNet shown in the diagram. For a new deployment, select **Create**, the resource group and region, and an approved nonoverlapping address space.
2. On **Subnets**, record actual names and address ranges in the worksheet. The small labels in the supplied diagram are not reproduced as authoritative CIDRs; use the network configuration as the source of truth.
3. Verify placement by workload rather than creating one subnet for all private endpoints:

   | Subnet / diagram area | Resources or purpose | Delegation |
   | --- | --- | --- |
   | Gateway subnet, right-hand gateway area | Application Gateway only | None |
   | `<WEB_WORKLOAD_SUBNET>`, web workload area | Web app inbound private endpoint; compatible existing workload resources can share this subnet | None |
   | `<WEB_INTEGRATION_SUBNET>`, beside the web workload area | App Service outbound VNet integration, not the inbound endpoint | `Microsoft.Web/serverFarms` |
   | `<SQL_WORKLOAD_SUBNET>`, left-hand SQL/data area | SQL private endpoint with existing data workload resources | None |
   | Existing Logic App and storage workload areas | Preserve existing endpoints and separate integration arrangement | Unchanged; private endpoints must be in nondelegated subnets |

4. Keep the gateway subnet dedicated to Application Gateway. Do not place VMs, deployment runners, or private endpoints there.
5. For a new VNet, use **Default (Azure-provided)** DNS. Preserve existing custom DNS and configure private-zone resolution/forwarding deliberately; do not change a domain-connected VNet's DNS just for this walkthrough.
6. Wait for each subnet update to finish before starting another. Preserve existing workload resources, NSGs, route tables, and the Logic App, DC, and Bastion subnets. Do not remove integration delegation to make room for an endpoint.
7. If an existing endpoint is in a different subnet, plan replacement, approval, DNS cutover, and NSG/ASG validation in a maintenance window. Do not leave an old unrestricted endpoint as an alternative access path.

### 2.2 Allow public HTTP to the gateway subnet

1. Open **Network security groups > Create** and create `nsg-appgateway`.
2. Open **Inbound security rules > Add**. Add the rules below. For every rule, use **Source port ranges = `*`**, **Destination = Any**, and **Service = Custom**.

   | Priority | Name | Source type and value | Destination ports | Protocol | Action |
   | --- | --- | --- | --- | --- | --- |
   | 100 | `Allow-Public-Http` | Service Tag: `Internet` | `80` | TCP | Allow |
   | 110 | `Allow-GatewayManager` | Service Tag: `GatewayManager` | `65200-65535` | Any | Allow |
   | 120 | `Allow-AzureLoadBalancer` | Service Tag: `AzureLoadBalancer` | `*` | Any | Allow |
   | 130 | `Deny-Other-Inbound` | Any | `*` | Any | Deny |

3. Open **Subnets > Associate**, and select the VNet and gateway subnet.
4. Verify the NSG appears on **Virtual network > Subnets > gateway subnet**.

The explicit deny must run before the default `AllowVNetInBound` rule at priority 65000. Retain the infrastructure allowances and do not add outbound deny rules as part of this guide. If approved private clients also need the public listener, add a specific source-CIDR allow for TCP 80 before the deny rule.

Only HTTP port 80 is exposed for application traffic. No public HTTPS listener or redirect is configured; inbound port 443 stays blocked on the gateway. For an existing gateway, replace obsolete upstream-only listener allowances with the intended client-source rules. The separate web endpoint NSG below still permits gateway-to-backend HTTPS on port 443.

### 2.3 Restrict only the web app private endpoint

1. Open **Application security groups > Create**. Create `asg-webapp-private-endpoint` in the same region.
2. Open the NSG already associated with `<WEB_WORKLOAD_SUBNET>`. If none exists, create `nsg-web-workload`. Do not replace an existing workload NSG.
3. Under **Inbound security rules**, add these rules. Use **Source port ranges = `*`** and **Destination = Application security group > asg-webapp-private-endpoint** for both. Select available priorities that keep this allow followed by this deny ahead of broad allows:

   | Priority | Name | Source type and value | Destination ports | Protocol | Action |
   | --- | --- | --- | --- | --- | --- |
   | 100 | `Allow-WebApp-Https-From-AppGateway` | IP Addresses: `<GATEWAY_SUBNET_CIDR>` | `443` | TCP | Allow |
   | 110 | `Deny-Other-WebApp-Inbound` | Any | `*` | Any | Deny |

4. Associate this NSG with **`<WEB_WORKLOAD_SUBNET>`**, not the delegated web integration subnet or SQL workload subnet.
5. Open **Virtual network > Subnets > `<WEB_WORKLOAD_SUBNET>`**.
6. Under **Network Policy for Private Endpoints**, enable **Network security groups** and leave **Route tables** unchecked. Save. This corresponds to `privateEndpointNetworkPolicies = NetworkSecurityGroupEnabled`.
7. If an NSG already exists on a shared subnet, reconcile these destination-ASG-scoped rules with it rather than replacing unrelated rules. The web deny must precede any broad allow that could permit other clients to the web endpoint.

Only the web endpoint will join this ASG in step 3. **Do not add the SQL, Logic App, or storage endpoints to it.** The ASG scopes these rules to the web endpoint, not its entire shared workload subnet. Enabling subnet network policies also affects other private endpoints there; review existing rules and retest those services.

### 2.4 Create private DNS zones and reserve the gateway address

1. Open **Private DNS zones > Create**, and create or reuse:
   - `privatelink.azurewebsites.net`
   - `privatelink.database.windows.net`
2. In each zone, open **Virtual network links > Add**. Select the application VNet and leave **Enable auto registration** unchecked.
3. Do not create a second App Service private DNS zone if the Logic App already uses the existing one. The endpoint wizards will add DNS zone groups and records to these zones.
4. Open **Public IP addresses > Create** and create `pip-appgateway`:
   - Same region as the gateway.
   - **IP version:** IPv4.
   - **SKU:** Standard; **Tier:** Regional.
   - **Assignment:** Static.
   - **Availability zones:** compatible with the intended gateway and supported by the chosen region.
5. Optionally open the public IP's **Configuration**, set its **DNS name label** to `agw-<suffix>`, and save. This is not required for IP-based access.
6. Copy the IP address from **Overview** as `<AGW_PUBLIC_IP>`. If configured, also copy the DNS name as `<AGW_FQDN>`. Leave the IP unassociated for now; step 5 attaches it to the gateway.
7. Use `http://<AGW_PUBLIC_IP>/` for access, or `http://<AGW_FQDN>/` if you configured the optional label. No custom public DNS record is required. Private DNS for the app and SQL endpoints remains required.

## 3. Windows App Service

### 3.1 Create the app and dedicated Windows plan

1. Open **App Services > Create > Web App**.
2. On **Basics**, select the resource group, a unique app name, **Publish = Code**, **Operating System = Windows**, and the chosen region.
3. Choose a supported runtime for the application you intend to deploy. The templates do not deploy application code or select a runtime for you.
4. Create/select a **separate Windows App Service plan**, `asp-webapp`, with **Standard S1** and one instance. Do not use the Logic App's Workflow Standard plan.
5. On **Networking**, disable public access. Complete **Review + create > Create**.
6. Open **Networking > Public network access** and verify **Disabled**. If shown under **Access restrictions**, use that page's public access control. A private endpoint alone does not disable public access.
7. Under **Configuration > General settings** and the corresponding TLS settings, configure:

   | Setting | Value |
   | --- | --- |
   | HTTPS Only | On |
   | Minimum inbound TLS / SCM TLS | 1.2 |
   | Always On | On |
   | Platform | 64 Bit |
   | HTTP version | 2.0 |
   | FTP state | Disabled |
   | Session affinity / ARR affinity | Off |

8. Save the changes and copy `<APP_HOST>` from **Overview**. Direct browsing is expected to be blocked.

Keep App Service **HTTPS Only** enabled: the gateway connects to it over HTTPS even though clients connect to the gateway over HTTP. This does not require a gateway listener certificate. Application-level redirects and sign-in requirements are separate; see step 5.4.

### 3.2 Assign the app identity

1. Search for **Managed Identities > Create**, and create `mi-webapp-sql` in the resource group and region.
2. Copy its **Client ID** and **Principal ID/Object ID** into the worksheet.
3. Open the web app's **Identity > User assigned > Add**.
4. Select `mi-webapp-sql`, add it, and save if prompted.
5. For a new app, leave its **System assigned** identity off to match the templates. Do not remove an existing identity until you have migrated any permissions assigned to it.

Attaching the identity does not grant SQL data access. No subscription-wide role or SQL administrator assignment is needed for this app identity.

### 3.3 Create the web private endpoint and DNS records

1. Open **Private endpoints > Create**. Use `pe-webapp`, the resource group, and the VNet's region.
2. On **Resource**, choose **Connect to an Azure resource in my directory**, resource type **Microsoft.Web/sites**, the Windows app, and target subresource **sites**.
3. On **Virtual Network**, select the application VNet and **`<WEB_WORKLOAD_SUBNET>`**, the nondelegated web workload subnet shown in the diagram. Do not select the gateway or outbound-integration subnet.
4. Select **asg-webapp-private-endpoint** under **Application security group**. Keep NSG network policies enabled.
5. On **DNS**, enable **Integrate with private DNS zone** and select the existing `privatelink.azurewebsites.net` zone. Complete creation.
6. Verify **Connection state = Approved** on the private endpoint and the app's private endpoint connections.
7. For an existing endpoint, open **Private endpoint > Settings > Application security groups**, select the web ASG, and save. Do not create a second, unrestricted endpoint.
8. Open **DNS configuration** and verify the app and SCM records point to this endpoint's private address. Record `<SCM_HOST>`.
9. Recheck the subnet's NSG policy after using the creation wizard; do not leave it disabled.

Keep the gateway backend hostname as `<APP_HOST>`, not the private IP or the `privatelink` hostname. Private DNS resolves the normal hostname privately while preserving the correct TLS certificate name and HTTP Host header.

### 3.4 Configure outbound integration for SQL

1. Open **Web app > Networking > VNet integration > Add VNet**.
2. Select the application VNet and **`<WEB_INTEGRATION_SUBNET>`**.
3. Confirm delegation to `Microsoft.Web/serverFarms`, apply, and wait for completion.
4. Leave all-traffic/Route All routing unchanged; this setup only requires private-address routing for SQL. Do not use `<WEB_WORKLOAD_SUBNET>`, `<SQL_WORKLOAD_SUBNET>`, or the Logic App's integration subnet.

VNet integration is **outbound** from App Service. It does not replace the **inbound** private endpoint or enforce gateway-only ingress.

## 4. Azure SQL Database and app connection

### 4.1 Create the SQL logical server and database

1. Open **SQL databases > Create**.
2. Select the resource group and set **Database name = appdb**.
3. Under **Server**, select **Create new**:
   - Use a globally unique server name and the same region.
   - Select **Use Microsoft Entra-only authentication**.
   - Use **Set admin** to select the intended Entra group/user. Do not choose the web app identity.
4. Do not use an elastic pool. Under **Compute + storage > Configure database**, choose the **DTU-based Basic** tier: **5 DTUs**, **2 GB** maximum storage.
5. Select **Locally-redundant backup storage** for parity with the demo. This is not a production availability recommendation.
6. On **Networking**, select **No access** while creating the resource; the next section adds its private endpoint. Do not enable a public endpoint, add the current client IP, or enable **Allow Azure services and resources to access this server**.
7. Create the empty database. Do not automatically create a Service Connector or SQL-password connection for the web app.
8. Open the **SQL logical server** resource, not just the database:
   - **Microsoft Entra ID:** verify the administrator and **Support only Microsoft Entra authentication for this server**. For an existing server, enabling this disables SQL-password authentication for all its databases; coordinate the change.
   - **Networking > Public access:** set/verify **Public network access = Disabled**.
   - **Networking > Connectivity:** verify minimum TLS **1.2**.
9. Copy `<SQL_FQDN>` from the server's **Overview**.

This is Azure SQL Database on a logical server, not SQL Server on a VM or SQL Managed Instance.

### 4.2 Add the SQL private endpoint

1. Open **Private endpoints > Create** and name the endpoint `pe-sql`.
2. On **Resource**, select resource type **Microsoft.Sql/servers**, the SQL logical server, and target subresource **sqlServer**.
3. Select the application VNet and **`<SQL_WORKLOAD_SUBNET>`**, the nondelegated SQL/data workload subnet shown in the diagram, not the web workload or integration subnet.
4. Leave **Application security group** unassigned. In particular, do not select the web-only ASG.
5. On **DNS**, enable integration with the existing `privatelink.database.windows.net` zone.
6. Create the endpoint, verify **Approved**, and verify its DNS configuration and VNet-linked private zone.
7. Recheck that the server's public network access remains **Disabled**.
8. Preserve the SQL workload subnet's NSG and route table. If private endpoint NSG policies are enabled there, verify that the existing rules permit required SQL traffic from `<WEB_INTEGRATION_SUBNET>` and approved administrative clients. Do not apply the web-only endpoint deny rules to SQL.

Both the web integration subnet and authorized private administrative clients need reachability to this SQL endpoint, including through existing workload egress restrictions. Verify the SQL connection policy's port requirements (TCP 1433 for Proxy; Redirect can require additional ports). Clients still need Entra authentication and database permissions. Always connect to `<SQL_FQDN>`, not the private IP or `privatelink` name.

### 4.3 Grant the app identity read/write access

The portal's **Access control (IAM)** pane does not create a SQL database user. This step executes T-SQL **inside `appdb`** as the configured SQL Entra administrator.

1. Use a browser on a workstation with VNet connectivity and private DNS resolution for the SQL server.
2. Open **SQL database > appdb > Query editor (preview)**.
3. Sign in with **Microsoft Entra authentication / Continue as ...**, using the SQL administrator account.
4. Use the current query editor experience where available. Microsoft's current guidance supports a private-network connection and uses HTTPS port 443. Do not enable public SQL access if the editor cannot connect.
5. If your portal experience or network does not support this connection, use SSMS or the VS Code MSSQL extension from the same private workstation. Alternatively, follow the existing [Initialize-WebAppDatabase.ps1 procedure](README.md#initialize-web-app-database-access), which performs guarded, idempotent creation and verification.
6. Replace `<MI_OBJECT_ID>` with the managed identity's **Principal ID/Object ID**, and run:

   ```sql
   SELECT CONVERT(varchar(34),
       CONVERT(binary(16), CONVERT(uniqueidentifier, '<MI_OBJECT_ID>')), 1)
       AS ManagedIdentitySid;
   ```

7. Copy the resulting `0x...` value as `<SID_HEX>`. Do not construct it by simply removing hyphens from the GUID: GUID byte order matters.
8. In the following batch, replace **every** `<IDENTITY_NAME>` with the identity resource name and **every** `<SID_HEX>` with that hexadecimal value, including `0x`, **without quotes**. Use the simple letters/digits/hyphen/underscore identity name selected above.
9. Run the batch in `appdb`:

   ```sql
   SET XACT_ABORT ON;
   IF DB_NAME() <> N'appdb'
       THROW 50000, 'Connect to appdb before changing permissions.', 1;

   BEGIN TRY
       BEGIN TRANSACTION;

       IF DATABASE_PRINCIPAL_ID(N'<IDENTITY_NAME>') IS NULL
           CREATE USER [<IDENTITY_NAME>] WITH SID = <SID_HEX>, TYPE = E;

       IF NOT EXISTS (
           SELECT 1 FROM sys.database_principals
           WHERE name = N'<IDENTITY_NAME>' AND sid = <SID_HEX> AND type = 'E'
       )
           THROW 50001, 'Existing user does not match the managed identity.', 1;

       GRANT CONNECT TO [<IDENTITY_NAME>];
       IF IS_ROLEMEMBER(N'db_datareader', N'<IDENTITY_NAME>') = 0
           ALTER ROLE db_datareader ADD MEMBER [<IDENTITY_NAME>];
       IF IS_ROLEMEMBER(N'db_datawriter', N'<IDENTITY_NAME>') = 0
           ALTER ROLE db_datawriter ADD MEMBER [<IDENTITY_NAME>];

       COMMIT TRANSACTION;
   END TRY
   BEGIN CATCH
       IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
       THROW;
   END CATCH;

   SELECT name, CONVERT(uniqueidentifier, sid) AS PrincipalId,
       IS_ROLEMEMBER(N'db_datareader', name) AS CanRead,
       IS_ROLEMEMBER(N'db_datawriter', name) AS CanWrite
   FROM sys.database_principals
   WHERE name = N'<IDENTITY_NAME>';
   ```

10. Confirm one result row: `PrincipalId` equals `<MI_OBJECT_ID>`, and both `CanRead` and `CanWrite` are `1`. On an identity mismatch, stop and investigate; do not drop or reassign an existing user blindly.

`TYPE = E` creates an external user for this managed identity. Supplying the SID avoids a Microsoft Graph name lookup and does not require granting the SQL server Directory Readers just for this operation. These grants allow SELECT/INSERT/UPDATE/DELETE on user tables, not schema management. Do not grant `db_owner` or `db_ddladmin`. Existing, manually elevated grants are not removed by this batch and must be reviewed separately.

### 4.4 Set the App Service connection settings

1. Return to **Web app > Settings > Environment variables** (called **Configuration > Application settings** in some portal layouts).
2. Add/update these **App settings**:

   | Name | Value |
   | --- | --- |
   | `AZURE_CLIENT_ID` | `<MI_CLIENT_ID>` |
   | `SQL_SERVER_FQDN` | `<SQL_FQDN>` |
   | `SQL_DATABASE_NAME` | `appdb` |

3. Under **Connection strings**, replace `DefaultConnection` (if present) with these two entries, both of type **SQLAzure**:

   **`MicrosoftDataSqlClient`** (driver-managed user-assigned identity authentication):

   ```text
   Server=tcp:<SQL_FQDN>,1433;Database=appdb;Authentication=Active Directory Managed Identity;User Id=<MI_CLIENT_ID>;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;
   ```

   **`SystemDataSqlClient`** (application-supplied access token):

   ```text
   Server=tcp:<SQL_FQDN>,1433;Database=appdb;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;
   ```

4. Apply/save and accept the app restart.
5. Deploy application code that reads the connection name matching its provider: `MicrosoftDataSqlClient` or `SystemDataSqlClient`. ASP.NET Core can use `Configuration.GetConnectionString(name)`; ASP.NET Framework can use `ConfigurationManager.ConnectionStrings[name].ConnectionString`. App Service exposes `SQLAZURECONNSTR_MicrosoftDataSqlClient` and `SQLAZURECONNSTR_SystemDataSqlClient`.

   - For Microsoft.Data.SqlClient, use a supported release with client-ID selection (v3+); v7+ also requires `Microsoft.Data.SqlClient.Extensions.Azure`.
   - For System.Data.SqlClient, use Azure.Identity to request a valid token for `https://database.windows.net/.default`, explicitly selecting the identity with the client ID in `AZURE_CLIENT_ID`. Set `SqlConnection.AccessToken` before opening each new connection and reuse the credential for token caching/refresh. Do not add `Authentication`, `User Id`, a password, or integrated authentication to this connection string; it cannot authenticate by itself.

The **client ID** selects the identity in application code; the **object ID** identifies its SQL user. They are not interchangeable. Both paths require the identity to be attached to the resource actually hosting the application; changing connection strings does not fix a missing identity assignment. Configuring these values does not make the platform landing page execute SQL or turn the app into a Windows domain account.

## 5. Application Gateway

### 5.1 Create a regional WAF policy

1. Search for **Web Application Firewall policies (WAF) > Create**.
2. Choose **Regional WAF (Application Gateway)**, the resource group and region, and name `waf-appgateway`.
3. Set **Policy state = Enabled** and **Policy mode = Prevention**. Keep request-body inspection enabled.
4. Under **Managed rules**, use **OWASP 3.2** for this walkthrough. Keep its rules enabled and review the appropriate managed rule set before production use.
5. Create/save the policy. Direct client access requires no upstream profile-ID header or custom allow rule.
6. If reusing a policy from an upstream-proxy-only design, remove its obsolete profile-ID/header blocking rules during the approved cutover; otherwise ordinary browser requests will be blocked. Preserve unrelated security rules.

Do not use a blanket custom **Allow** rule to make requests succeed: it could skip the managed rules.

### 5.2 Create the gateway, listener, and backend

1. Open **Application gateways > Create > Application Gateway**.
2. On **Basics**, choose:
   - The resource group, gateway name, and region.
   - **Tier = WAF V2**.
   - **Autoscaling = Enabled**, minimum **2**, maximum **4** instances.
   - Availability zones compatible with the public IP.
   - The existing application VNet and **gateway subnet**.
   - The regional WAF policy `waf-appgateway`.
3. On **Frontends**, choose a **Public IPv4** frontend and select the existing `pip-appgateway`. Its `<AGW_PUBLIC_IP>` is the public entry point; no hostname binding is required.
4. On **Backends**, add a pool named `webapp`:
   - **Target type = IP address or FQDN**.
   - **Target = `<APP_HOST>`**, the normal App Service default hostname.
   - Add no other targets, Logic App hostname, or SCM hostname.
5. On **Configuration**, add a routing rule:
   - **Name:** `web-app`; **Priority:** `100`.
   - **Listener:** new `http-public`; public frontend; protocol **HTTP**; port **80**; listener type **Basic**. Do not configure a hostname restriction.
   - **Certificate:** none. An HTTP listener does not require a certificate upload or Key Vault reference.
   - **Backend target:** backend pool `webapp`, not a redirect.
6. Add backend settings named `webapp-https`:

   | Setting | Value |
   | --- | --- |
   | Backend protocol / port | HTTPS / 443 |
   | Backend certificate validation | Enabled; use the well-known/public CA option |
   | Override hostname | Yes |
   | Hostname override source | Pick hostname from backend target |
   | Cookie-based affinity | Disabled |
   | Connection draining | Disabled |
   | Request timeout | 30 seconds |

7. Save the settings and routing rule, review, and create the gateway.
8. Wait for provisioning to succeed. For an existing gateway, check **Web application firewall** and verify this policy is associated with the gateway; also inspect listener/path-level policy overrides so another policy cannot bypass the checks.
9. Under **Configuration**, enable/verify **HTTP/2** support. Do not add extra listeners or routes to the Logic App.
10. No frontend TLS policy is needed for this HTTP listener. When adapting a demo gateway, retire unused HTTPS listeners, redirects, and inbound 443 allowances after verifying the HTTP path. Do not downgrade an existing production or authenticated application to HTTP.

The NSG from step 2 must already be attached. Public HTTP to this gateway is intentional; direct public or private access to the App Service backend remains blocked. Keep public port 443 closed and do not expose SCM through an additional listener or route.

### 5.3 Add the custom backend probe

1. Open **Application Gateway > Health probes > Add**.
2. Configure:

   | Setting | Value |
   | --- | --- |
   | Name | `webapp-https-probe` |
   | Protocol | HTTPS |
   | Host | `<APP_HOST>` |
   | Pick hostname from backend settings | No, when entering the explicit Host above |
   | Port | Use backend settings port, 443 |
   | Path | `/` |
   | Interval / timeout | 30 / 30 seconds |
   | Unhealthy threshold | 3 |
   | Acceptable HTTP status codes | `200-399` |
   | Response-body match | None |

3. Save, then open **Backend settings > webapp-https**, enable **Use custom probe**, select this probe, and save. If the probe editor lets you associate backend settings directly, verify the association there as well.
4. Open **Backend health** and wait for the web app to become **Healthy**.
5. Open `http://<AGW_PUBLIC_IP>/` and verify the gateway serves the demo app without redirecting to HTTPS or sign-in. Do not accept 4xx responses as healthy to hide a backend error.

The gateway's own probes originate from its subnet and are allowed by the web endpoint NSG. Do not weaken the web endpoint rules to make a private workstation's direct request succeed.

### 5.4 HTTP demo compatibility

1. Use a new or explicitly approved demo app that serves anonymous, non-sensitive content. Do not remove authentication from an existing protected application just to make this walkthrough work.
2. Do not configure Microsoft Entra Easy Auth sign-in for this public HTTP URL. Web sign-in redirect URIs require HTTPS except for localhost development, and authentication cookies must not be sent over this unencrypted path.
3. If the demo app redirects to HTTPS, inspect its HTTPS-redirection middleware, forwarded-protocol handling, and authentication settings. The gateway's backend request is HTTPS, but the original client request is HTTP. Adjust only the isolated demo configuration; do not turn off backend certificate validation or SQL encryption.
4. Verify `http://<AGW_PUBLIC_IP>/` returns the intended content without a redirect to an inaccessible app hostname, HTTPS listener, or sign-in page. A healthy probe alone does not prove this, because it can accept 3xx responses.

Entra managed identity authentication from the app to SQL is unaffected; it is separate from end-user browser sign-in.

## 6. Diagnostics

1. Create or reuse a **Log Analytics workspace** in the resource group; use 30-day retention for parity with the templates.
2. Open **Application Gateway > Diagnostic settings > Add diagnostic setting**. Send **allLogs** and **AllMetrics** to that workspace, including access and firewall logs.
3. Open **Web app > Diagnostic settings**. Send **allLogs** and **AllMetrics** to the workspace.
4. Use **Application Gateway > Backend health**, gateway **Metrics**, and workspace logs to investigate failures. SQL diagnostics/auditing can be configured separately; they are not added by this repository's current SQL template.

## 7. Acceptance checks and troubleshooting

Use fresh connections after settings propagate. Existing NSG-tracked sessions may survive a rule update.

| Check | Where/how | Expected result |
| --- | --- | --- |
| Public entry point | Browser: `http://<AGW_PUBLIC_IP>/` | Demo app content or landing page over HTTP, without a forced HTTPS or sign-in redirect |
| Optional public DNS | Browser: `http://<AGW_FQDN>/`, if configured | Resolves to `<AGW_PUBLIC_IP>` and serves the same demo content |
| Public HTTPS blocked | TCP test to `<AGW_PUBLIC_IP>` on port 443 | TCP connection cannot complete; no HTTPS listener configured |
| Regional WAF | Gateway policy association and firewall logs | Enabled, Prevention mode, managed rules active; no upstream profile-ID header required |
| Gateway backend | Gateway **Backend health** | `<APP_HOST>` healthy over HTTPS |
| Endpoint placement | Private endpoints **Overview > Virtual network/subnet** | Web endpoint in `<WEB_WORKLOAD_SUBNET>`; SQL endpoint in `<SQL_WORKLOAD_SUBNET>`; neither in the gateway or delegated integration subnet |
| Public web/SCM bypass | Internet client: app and SCM default hostnames | Access denied; public network access stays disabled |
| Private web/SCM bypass | VNet client outside gateway subnet: app and SCM hostnames | DNS resolves privately, but TCP 443 is denied |
| SQL network settings | SQL server **Networking**, private endpoint, and DNS configuration | Public access disabled; private connection approved; FQDN resolves privately |
| SQL user | Query in step 4.3 | Correct object ID and both data roles present |
| Actual application SQL access | Deployed app using its managed identity | Data read/write succeeds; schema creation/alteration fails for this identity |
| Existing private services | Existing authorized private clients | Logic App, storage, and administrative SQL access remain functional |

For a bounded direct-gateway HTTP test from an Internet-connected PowerShell client:

```powershell
curl.exe --include --connect-timeout 10 --max-time 15 "http://<AGW_PUBLIC_IP>/"
```

This request should return the demo content through Application Gateway. Inspect any `Location` response header: a redirect to HTTPS or sign-in does not pass this HTTP-only walkthrough. If using the optional DNS label, repeat against `http://<AGW_FQDN>/` to verify resolution.

For negative backend-access tests, confirm private DNS resolves correctly and the gateway path succeeds first. A DNS typo or unrelated outage does not prove access restrictions are working.

For the SQL application test, have the SQL administrator create a disposable table, run SELECT/INSERT/UPDATE/DELETE from the **application identity** inside a transaction and roll it back, and verify that identity cannot CREATE/ALTER tables. Have the administrator remove the table afterward. An administrator's successful query does not prove the app can connect. The platform landing page contains no SQL test code.

### Common failures

| Symptom | Check first |
| --- | --- |
| Public HTTP timeout | Correct gateway public IP, NSG allows client sources on 80, Basic HTTP listener and routing rule are enabled, and gateway provisioning succeeded |
| Redirect to HTTPS/sign-in or backend 401 | Demo app authentication, HTTPS-redirection middleware, and forwarded-protocol handling; follow step 5.4, not a blanket removal of production security |
| Gateway 502 | Backend health, private DNS, endpoint approval, NSG rules, backend Host/SNI, and probe response |
| Gateway 403 | Firewall logs and managed/custom rules; remove obsolete upstream-only header requirements during cutover, not WAF protection |
| Gateway backend unhealthy | Web private endpoint approval, normal app FQDN resolving privately, private DNS VNet link, NSG policies, ASG membership, HTTPS Host/SNI and probe response |
| Web app reachable directly from a private client | NSG policies disabled, endpoint missing from ASG, wrong destination ASG, a broad allow, or an additional unrestricted private endpoint |
| SQL token login failure | Wrong identity selected, client ID used instead of object ID for user SID, wrong database/tenant, or missing database user/roles |
| SQL connection timeout | Web VNet integration, SQL private DNS/endpoint, and any pre-existing egress rules; do not fix by enabling public SQL access |
| Query editor cannot connect | Private connectivity/DNS, administrator identity, current vs. classic editor, and HTTPS connectivity; use the private-workstation fallback |
| Kudu/ZIP deployment cannot connect | Expected under strict web-app gateway-only private endpoint rules; see the deployment limitation below |

Do not solve health failures by disabling WAF, accepting 4xx as healthy, turning off backend TLS validation, or broadly opening the NSGs.

## 8. Before production use

### Web app deployment limitation

The App Service site and SCM/Kudu endpoint share the private endpoint IP and HTTPS port. The gateway-only NSG therefore blocks direct SCM access from deployment runners. The gateway always selects the app's backend hostname; it does not expose SCM.

Do not publish SCM through Application Gateway or place a deployment runner in the gateway subnet. Design an approved pull-based deployment, such as [running from an external package URL](https://learn.microsoft.com/azure/app-service/deploy-run-package#run-from-external-url-instead), with private package storage, managed-identity read permissions, and outbound reachability. This guide does not provision that pipeline. Check the documented migration limitation for apps already running a local ZIP package.

### Demo boundaries and operational readiness

This HTTP public entry point is not suitable for production or sensitive traffic. No frontend certificate setup is part of this walkthrough.

1. Keep this deployment limited to non-sensitive demo content. A production or authenticated deployment needs a separately designed secure ingress path.
2. Retain HTTPS and certificate validation on the private App Service backend, and keep SQL encryption enabled. Neither requires a public listener certificate.
3. Validate WAF exclusions against actual application traffic. Add alerts for unhealthy backends and rejected requests.
4. Review shared workload-subnet NSGs and routes after enabling private endpoint network policies; verify unrelated services still work.
5. Reconcile this topology with infrastructure as code in a separate change before using template deployments to manage these resources again. This guide alone does not change templates or remove existing cloud resources.

Also review end-user authentication, forwarded host/scheme handling in the application, SQL sizing/backups, monitoring/alerts, and resilience. Network isolation and managed identity do not supply application authorization.

## References

- [Application Gateway portal quickstart](https://learn.microsoft.com/azure/application-gateway/quick-create-portal)
- [Application Gateway with App Service](https://learn.microsoft.com/azure/application-gateway/configure-web-app)
- [Application Gateway infrastructure and NSG requirements](https://learn.microsoft.com/azure/application-gateway/configuration-infrastructure)
- [App Service private endpoints](https://learn.microsoft.com/azure/app-service/overview-private-endpoint)
- [App Service VNet integration](https://learn.microsoft.com/azure/app-service/overview-vnet-integration)
- [Private endpoint application security groups](https://learn.microsoft.com/azure/private-link/configure-asg-private-endpoint)
- [Enable private endpoint network policies in the portal](https://learn.microsoft.com/azure/private-link/disable-private-endpoint-network-policy)
- [Enable Microsoft Entra-only SQL authentication](https://learn.microsoft.com/azure/azure-sql/database/authentication-azure-ad-only-authentication-tutorial)
- [Azure SQL portal query editor and private-network connection considerations](https://learn.microsoft.com/azure/azure-sql/database/query-editor)
- [Claims customization using PowerShell and Claims Mapping Policy](https://learn.microsoft.com/en-us/entra/identity-platform/claims-customization-powershell)
- [Deploying to Network-secured sites](https://azure.github.io/AppService/2021/03/01/deploying-to-network-secured-sites-2.html)
- [Configure an application to trust a managed identity](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity?tabs=microsoft-entra-admin-center%2Cdotnet)
- [Configure your App Service or Azure Functions app to use Microsoft Entra sign-in](https://learn.microsoft.com/en-us/azure/app-service/configure-authentication-provider-aad?tabs=workforce-configuration)