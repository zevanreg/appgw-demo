<%@ Page Title="User Claims" Language="C#" MasterPageFile="~/Site.Master" AutoEventWireup="true" CodeBehind="Default.aspx.cs" Inherits="DemoClaims._Default" %>

<asp:Content ID="BodyContent" ContentPlaceHolderID="MainContent" runat="server">
    <div class="page-header">
        <h1>User claims</h1>
    </div>

    <p class="lead">
        <asp:Literal ID="AuthenticationStatus" runat="server" />
    </p>

    <div class="table-responsive">
        <asp:GridView ID="ClaimsGrid" runat="server"
            AutoGenerateColumns="false"
            CssClass="table table-striped table-bordered"
            EmptyDataText="The current identity does not contain any claims."
            EnableViewState="false"
            GridLines="None">
            <Columns>
                <asp:BoundField DataField="AuthenticationType" HeaderText="Authentication type" HtmlEncode="true" />
                <asp:BoundField DataField="Type" HeaderText="Type" HtmlEncode="true" />
                <asp:BoundField DataField="Value" HeaderText="Value" HtmlEncode="true" />
                <asp:BoundField DataField="ValueType" HeaderText="Value type" HtmlEncode="true" />
                <asp:BoundField DataField="Issuer" HeaderText="Issuer" HtmlEncode="true" />
                <asp:BoundField DataField="OriginalIssuer" HeaderText="Original issuer" HtmlEncode="true" />
            </Columns>
        </asp:GridView>
    </div>

    <div class="page-header">
        <h2>Database user</h2>
    </div>

    <h3>Microsoft.Data.SqlClient</h3>

    <p>
        <asp:Literal ID="MicrosoftDataSqlClientStatus" runat="server" />
    </p>

    <div class="table-responsive">
        <asp:GridView ID="MicrosoftDataSqlClientGrid" runat="server"
            AutoGenerateColumns="true"
            CssClass="table table-striped table-bordered"
            EnableViewState="false"
            GridLines="None"
            Visible="false" />
    </div>

    <h3>System.Data.SqlClient with managed identity access token</h3>

    <p>
        <asp:Literal ID="SystemDataSqlClientStatus" runat="server" />
    </p>

    <div class="table-responsive">
        <asp:GridView ID="SystemDataSqlClientGrid" runat="server"
            AutoGenerateColumns="true"
            CssClass="table table-striped table-bordered"
            EnableViewState="false"
            GridLines="None"
            Visible="false" />
    </div>
</asp:Content>
