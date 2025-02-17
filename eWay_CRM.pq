// This file contains your Data Connector logic
[Version = "2.0.0"]
section eWayCRM;

[DataSource.Kind="eWayCRM", Publish="eWayCRM.Publish"]
shared eWayCRM.Contents = Value.ReplaceType(eWayCRM_Implementation, eWayCRM_Type);

eWayCRM.Data = (FolderName as text, optional IncludeRelations as logical) =>
    let
        SessionResult = CreateSession(Extension.CurrentCredential()),
        ApiUrl = SessionResult[ApiUrl],
        SessionId = SessionResult[SessionId],
        IncludeRelations = if (IncludeRelations = null) then false else IncludeRelations,
        IncludeRelationsParameter = if (IncludeRelations = true) then "true" else "false",
        AdditionalFieldsUrl = ApiUrl & "/SearchAdditionalFields",
        AdditionalFieldsBody = "{ ""sessionId"": """ & SessionId & """,	""transmitObject"": { ""ObjectTypeFolderName"": """ & FolderName & """ } }",
        AdditionalFields = Json.Document(Web.Contents(AdditionalFieldsUrl,
            [
                Headers = [#"Content-Type"="application/json"],
                Content = Text.ToBinary(AdditionalFieldsBody),
                Timeout=#duration(0, 0, 1, 0)
            ]
        )),
        AdditionalFieldsJsonData = AdditionalFields[Data],
        AdditionalFieldsJsonDataTable = Table.FromList(AdditionalFieldsJsonData, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        AdditionalFieldsTable = FilterAdditionalFields(ExpandRows(AdditionalFieldsJsonDataTable, InsertStandardFieldsToSchema(GetSchemaForEntity("AdditionalFields")), IncludeRelations)),
        IdentifiersUrl = ApiUrl & "Get" & FolderName & "Identifiers",
        IdentifiersBody = "{ ""sessionId"": """ & SessionId & """ }",
        IdentifiersResult = Json.Document(Web.Contents(IdentifiersUrl,
            [
                Headers = [#"Content-Type"="application/json"],
                Content = Text.ToBinary(IdentifiersBody),
                Timeout=#duration(0, 0, 5, 0)
            ]
        )),
        JsonIdentifiers = IdentifiersResult[Data],
        JsonIdentifiersTable = Table.FromList(JsonIdentifiers, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        IdentifiersTable = ExpandRows(JsonIdentifiersTable, InsertStandardFieldsToSchema(GetSchemaForEntity(FolderName)), IncludeRelations, AdditionalFieldsTable),
        IdentifiersList = Table.Column(IdentifiersTable, "ItemGUID"),
        PageCount = Number.RoundUp(List.Count(IdentifiersList) / itemsPerPage),
        PageIndices = { 0 .. PageCount - 1 },
        Pages = List.Transform(PageIndices, each GetItemsByItemGuids(_, ApiUrl, FolderName, SessionId, IdentifiersList, IncludeRelationsParameter)),
        JsonData = List.Combine(Pages),
        JsonDataTable = Table.FromList(JsonData, Splitter.SplitByNothing(), null, null, ExtraValues.Error),
        LogoutResult = Logout(ApiUrl, SessionId),
        Table = if JsonDataTable <> null and LogoutResult[ReturnCode] = "rcSuccess" 
                    then ExpandRows(JsonDataTable, InsertStandardFieldsToSchema(GetSchemaForEntity(FolderName)), IncludeRelations, AdditionalFieldsTable) 
                    else "API Error: " & ToJsonString(LogoutResult)
    in
        Table;

CreateSession = (Credential as record) =>
    let
        WebServiceUrl = GetWebServiceFromToken(Credential[access_token]),
        UserName = GetUserNameFromToken(Credential[access_token]),
        ApiUrl = if (Text.StartsWith(WebServiceUrl, "http://")) then WebServiceUrl & "InsecureAPI.svc/" else WebServiceUrl & "API.svc/",
        LoginUrl = ApiUrl & "Login",
        SessionBody = "{ ""userName"": """ & UserName & """, ""appVersion"": ""PowerBI_Connector_200"", ""clientMachineIdentifier"": ""B39B35C4-70B3-4495-A1D4-258F3E557C19"" }",
        SessionResult = Json.Document(Web.Contents(LoginUrl,
            [
                Headers = [#"Content-Type"="application/json"],
                Content = Text.ToBinary(SessionBody),
                IsRetry = true
            ]
        )),
        SessionId = SessionResult[SessionId]
    in
        [SessionId = SessionId, ApiUrl = ApiUrl];

QueryPageSize = 1000;

UseQuery = (Query as text, optional Skip as number, optional SessionIdParam as text, optional ApiUrlParam as text) => 
    let
        QueryJson = Json.Document(Query),
        QueryJsonWithPaging = if Record.HasFields(QueryJson, "Paging") = false then AddPagingToQuery(QueryJson, QueryPageSize, if Skip = null then 0 else Skip) else QueryJson,
        SessionResult = if SessionIdParam = null then CreateSession(Extension.CurrentCredential()) else null,
        ApiUrl = if SessionResult = null then ApiUrlParam else SessionResult[ApiUrl],
        SessionId = if SessionResult = null then SessionIdParam else SessionResult[SessionId],
        QueryBody = "{ ""sessionId"": """ & SessionId & """, ""query"": " & Text.FromBinary(Json.FromValue(QueryJsonWithPaging)) & " }",
        QueryResult = Json.Document(Web.Contents(ApiUrl & "Query",
            [
                Headers = [#"Content-Type"="application/json"],
                Content = Text.ToBinary(QueryBody),
                IsRetry = true
            ]
        )),

        AgregatedDataTable = 
            if 
                Record.HasFields(QueryJson, "Paging") = false and List.Count(QueryResult[Data]) = QueryPageSize 
            then 
                Table.Combine({Table.FromRecords(QueryResult[Data]), @UseQuery(Text.FromBinary(Json.FromValue(QueryJson)), if Skip = null then QueryPageSize else Skip + QueryPageSize, SessionId, ApiUrl)}) 
            else 
                Table.FromRecords(QueryResult[Data]),

        LogoutResult = if AgregatedDataTable <> null and  SessionResult <> null then Logout(ApiUrl, SessionId) else [ReturnCode="rcSuccess"],

        Table = if QueryResult[Data] <> null and LogoutResult[ReturnCode] = "rcSuccess" 
                    then AgregatedDataTable
                    else "Query error: " & ToJsonString(QueryResult)
    in
        Table;

UseQueryAmount = (Query as text) => 
    let
        SessionResult = CreateSession(Extension.CurrentCredential()),
        ApiUrl = SessionResult[ApiUrl],
        SessionId = SessionResult[SessionId],
        QueryBody = "{ ""sessionId"": """ & SessionId & """, ""query"": " & Query & " }",
        QueryResult = Json.Document(Web.Contents(ApiUrl & "QueryAmount",
            [
                Headers = [#"Content-Type"="application/json"],
                Content = Text.ToBinary(QueryBody),
                IsRetry = true
            ]
        )),
        LogoutResult = Logout(ApiUrl, SessionId),
        Table = if QueryResult[Datum] <> null and LogoutResult[ReturnCode] = "rcSuccess" 
                    then Table.FromRecords({[Datum = QueryResult[Datum]]}) 
                    else "Query error: " & ToJsonString(QueryResult)
    in
        Table;

Query = (Query as nullable text, IsQueryAmount as nullable logical) => 
    let
        ResultTable = 
            if Query = null
                then
                    #table({}, {[]})
                else
                    if IsQueryAmount = true
                        then
                            UseQueryAmount(Query)
                        else
                            UseQuery(Query)              
    in
        ResultTable;

AddPagingToQuery = (QueryObject as record, TakeParam as number, SkipParam as number) =>
    Record.AddField(QueryObject, "Paging", [ Take=TakeParam, Skip=SkipParam ]);

GetItemsByItemGuids = (Index, ApiUrl, FolderName, SessionId, IdentifiersList, IncludeRelationsParameter) =>
    let
        Part = List.Range(IdentifiersList, Index * itemsPerPage, itemsPerPage),
        Combined = "[""" & Text.Combine(Part, """, """) & """]",
        DataUrl = ApiUrl & "Get" & FolderName & "ByItemGuids",
        DataBody = "{ ""sessionId"": """ & SessionId & """, ""itemGuids"": " & Combined & ", ""includeRelations"": " & IncludeRelationsParameter & ", ""includeForeignKeys"": true, ""omitGoodsInCart"": true }",
        DataResult = Json.Document(Web.Contents(DataUrl,
            [
                Headers = [#"Content-Type"="application/json"],
                Content = Text.ToBinary(DataBody),
                Timeout=#duration(0, 0, 5, 0)
            ]
        )),
        JsonData = DataResult[Data]
    in
        JsonData;

Logout = (ApiUrl, SessionId) =>
    let
        LogoutUrl = ApiUrl & "LogOut",
        LogoutBody = "{ ""sessionId"": """ & SessionId & """ }"
    in
        Json.Document(Web.Contents(LogoutUrl,
            [
                Headers = [
                    #"Content-Type"="application/json",
                    RequestGUID=Text.NewGuid()
                ],
                Content = Text.ToBinary(LogoutBody),
                Timeout=#duration(0, 0, 0, 10),
                IsRetry=true
            ]
        ));

ToJsonString = (obj as any) =>
    Text.FromBinary(Json.FromValue(obj));

Base64UrlToBase64 = (base64Url) =>
    let
        base64 = AddPaddingToBase64String(Text.Replace(Text.Replace(base64Url, "-", "+"), "_", "/"))
    in
        base64;

AddPaddingToBase64String = (base64) =>
    let
        base64 = if (Number.Mod(Text.Length(base64), 4)) <> 0 then @AddPaddingToBase64String(base64 & "=") else base64
    in
        base64;

GetWebServiceFromToken = (token) =>
    let
        Json = Json.Document(Binary.FromText(Base64UrlToBase64(Text.Split(token, "."){1}), BinaryEncoding.Base64)),
        WebService = Record.Field(Json, "ws") & "/"
    in
        WebService;

GetWebServiceFromRefreshToken = (token) =>
    let
        WebService = Text.FromBinary(Binary.FromText(Base64UrlToBase64(Text.Split(token, "."){1}), BinaryEncoding.Base64))
    in
        WebService;

GetUserNameFromToken = (token) =>
    let
        Json = Json.Document(Binary.FromText(Base64UrlToBase64(Text.Split(token, "."){1}), BinaryEncoding.Base64)),
        UserName = Record.Field(Json, "username")
    in
        UserName;

eWayCRM_Type = type function (
    optional options as (
        type nullable [
            optional IncludeRelations = (type logical meta [
                Documentation.FieldCaption = "Include Relations",
                Documentation.FieldDescription = "Load also relations between items.",
                Documentation.AllowedValues = {
                    false meta [ Documentation.Caption = "False" ],
                    true meta [ Documentation.Caption = "True" ]
                }
            ]),
            optional Query = (type text meta [
                Documentation.FieldCaption = "Query",
                Documentation.FieldDescription = "Query to be executed.",
                Formatting.IsMultiLine = true,
                Formatting.IsCode = true
            ]),
            optional QueryAmount = (type logical meta [
                Documentation.FieldCaption = "Query Amount",
                Documentation.FieldDescription = "If set to ""true"" query will only return count of the items."
                & " of returning the underlying data",
                Documentation.AllowedValues = {
                    false meta [ Documentation.Caption = "False" ],
                    true meta [ Documentation.Caption = "True" ]
                }
            ])
        ] meta [
            Documentation.FieldCaption = "Advanced options"
        ]))
    as table;

eWayCRM_Implementation = (optional options as any) =>
    let
        IncludeRelations = if 
            options = true or (options <> null and Type.Is(Value.Type(options), type record) and Record.HasFields(options, "IncludeRelations") and Record.Field(options, "IncludeRelations") = true) 
                then true 
                else false,
                
        Objects = #table(
            { "Name", "Key", "Data", "ItemKind", "ItemName", "IsLeaf" }, {
            { "Bookkeeping", "Carts", eWayCRM.Data("Carts", IncludeRelations), "Table", "Table", true},
            { "Calendar", "Calendars", eWayCRM.Data("Calendars", IncludeRelations), "Table", "Table", true},
            { "Categories", "Groups", eWayCRM.Data("Groups", IncludeRelations), "Table", "Table", true},
            { "Custom Fields", "AdditionalFields", eWayCRM.Data("AdditionalFields", IncludeRelations), "Table", "Table", true},
            { "Companies", "Companies", eWayCRM.Data("Companies", IncludeRelations), "Table", "Table", true},
            { "Contacts", "Contacts", eWayCRM.Data("Contacts", IncludeRelations), "Table", "Table", true},
            { "Deals", "Leads", eWayCRM.Data("Leads", IncludeRelations), "Table", "Table", true},
            { "Discount Lists", "SalePrices", eWayCRM.Data("SalePrices", IncludeRelations), "Table", "Table", true},
            { "Documents", "Documents", eWayCRM.Data("Documents", IncludeRelations), "Table", "Table", true},
            { "Drop Down Menu", "EnumTypes", eWayCRM.Data("EnumTypes", IncludeRelations), "Table", "Table", true},
            { "Drop Down Menu Values", "EnumValues", eWayCRM.Data("EnumValues", IncludeRelations), "Table", "Table", true},
            { "Emails", "Emails", eWayCRM.Data("Emails", IncludeRelations), "Table", "Table", true},
            { "Exchange Rates", "CurrencyExchangeRates", eWayCRM.Data("CurrencyExchangeRates", IncludeRelations), "Table", "Table", true},
            { "Features", "Features", eWayCRM.Data("Features", IncludeRelations), "Table", "Table", true},
            { "Flows", "Flows", eWayCRM.Data("Flows", IncludeRelations), "Table", "Table", true},
            { "Global Settings", "GlobalSettings", eWayCRM.Data("GlobalSettings", IncludeRelations), "Table", "Table", true},
            { "Goals", "Goals", eWayCRM.Data("Goals", IncludeRelations), "Table", "Table", true},
            { "Journal", "Journals", eWayCRM.Data("Journals", IncludeRelations), "Table", "Table", true},
            { "Marketing", "MarketingCampaigns", eWayCRM.Data("MarketingCampaigns", IncludeRelations), "Table", "Table", true},
            { "Marketing List", "MarketingListsRecords", eWayCRM.Data("MarketingListsRecords", IncludeRelations), "Table", "Table", true},
            { "Multi Select Drop Down Relations", "EnumValuesRelations", eWayCRM.Data("EnumValuesRelations", IncludeRelations), "Table", "Table", true},
            { "Products", "Goods", eWayCRM.Data("Goods", IncludeRelations), "Table", "Table", true},
            { "Products in Bookkeeping Record", "GoodsInCart", eWayCRM.Data("GoodsInCart", IncludeRelations), "Table", "Table", true},
            { "Projects", "Projects", eWayCRM.Data("Projects", IncludeRelations), "Table", "Table", true},
            { "Recurrence Patterns", "RecurrencePatterns", eWayCRM.Data("RecurrencePatterns", IncludeRelations), "Table", "Table", true},
            { "Tasks", "Tasks", eWayCRM.Data("Tasks", IncludeRelations), "Table", "Table", true},
            { "Time Sheets", "WorkReports", eWayCRM.Data("WorkReports", IncludeRelations), "Table", "Table", true},
            { "Workflow Diagrams", "WorkflowModels", eWayCRM.Data("WorkflowModels", IncludeRelations), "Table", "Table", true},
            { "Workflow History", "WorkflowHistoryRecords", eWayCRM.Data("WorkflowHistoryRecords", IncludeRelations), "Table", "Table", true},
            { "Users", "Users", eWayCRM.Data("Users", IncludeRelations), "Table", "Table", true},
            { "User Settings", "UserSettings", eWayCRM.Data("UserSettings", IncludeRelations), "Table", "Table", true},
            { "Query", "Query", if options <> null then Query(options[Query], options[QueryAmount]) else Query(null, null), "Table", "Table", true}
            }),
        NavTable = Table.ToNavigationTable(Objects, {"Key"}, "Name", "Data", "ItemKind", "ItemName", "IsLeaf")
    in
        NavTable;

Table.ToNavigationTable = (
    table as table,
    keyColumns as list,
    nameColumn as text,
    dataColumn as text,
    itemKindColumn as text,
    itemNameColumn as text,
    isLeafColumn as text
) as table =>
    let
        tableType = Value.Type(table),
        newTableType = Type.AddTableKey(tableType, keyColumns, true) meta 
        [
            NavigationTable.NameColumn = nameColumn, 
            NavigationTable.DataColumn = dataColumn,
            NavigationTable.ItemKindColumn = itemKindColumn, 
            Preview.DelayColumn = itemNameColumn, 
            NavigationTable.IsLeafColumn = isLeafColumn
        ],
        navigationTable = Value.ReplaceType(table, newTableType)
    in
        navigationTable;

// OAuth2 flow definition
redirectUri = "https://oauth.powerbi.com/views/oauthredirect.html";
windowWidth = 458;
windowHeight = 498;
clientId = "powerbi";
clientSecret = Text.FromBinary(Extension.Contents("client_secret"));
itemsPerPage = 2000;

CreateSha256Hash = (codeVerifier) =>
    let
        Hash = Crypto.CreateHash(CryptoAlgorithm.SHA256, Text.ToBinary(codeVerifier)),
        Base64Text = Binary.ToText(Hash, BinaryEncoding.Base64),
        Base64TextTrimmed = Text.TrimEnd(Base64Text, "="),
        Base64Url = Text.Replace(Text.Replace(Base64TextTrimmed, "+", "-"), "/", "_")
    in
        Base64Url;

StartLogin = (resourceUrl, state, display) =>
    let
        CodeVerifier = Text.NewGuid() & Text.NewGuid(),
        AuthorizeUrl = "https://login.eway-crm.com/?" & Uri.BuildQueryString([
            client_id = clientId,
            scope = "api offline_access",
            state = state,
            redirect_uri = redirectUri,
            code_challenge = CreateSha256Hash(CodeVerifier),
            code_challenge_method = "S256",
            response_type = "code",
            prompt = "login"])
    in
        [
            LoginUri = AuthorizeUrl,
            CallbackUri = redirectUri,
            WindowHeight = windowHeight,
            WindowWidth = windowWidth,
            Context = CodeVerifier
        ];

FinishLogin = (context, callbackUri, state) =>
    let
        Parts = Uri.Parts(callbackUri)[Query]
    in
        TokenMethod(Parts[code], "authorization_code", Parts[ws_url], context);

TokenMethod = (code, grant_type, ws_url, optional verifier) =>
    let
        CodeVerifier = if (verifier <> null) then [code_verifier = verifier] else [],
        Response = Web.Contents(ws_url & "/auth/connect/token", [
            Content = Text.ToBinary(Uri.BuildQueryString(CodeVerifier & [
                client_id = clientId,
                client_secret = clientSecret,
                code = code,
                refresh_token = code,
                redirect_uri = redirectUri,
                grant_type = grant_type])),
            Headers=[#"Content-type" = "application/x-www-form-urlencoded",#"Accept" = "application/json"]]),
        Parts = Json.Document(Response)
    in
        Parts;

Refresh = (resourceUrl, refresh_token) =>
    let
        WebService = GetWebServiceFromRefreshToken(refresh_token),
        Parts = TokenMethod(refresh_token, "refresh_token", WebService)
    in
        Parts;

// Data Source Kind description
eWayCRM = [
    TestConnection = (dataSourcePath) => { "eWayCRM.Contents" },
    Authentication = [
        OAuth = [
            StartLogin = StartLogin,
            FinishLogin = FinishLogin,
            Refresh = Refresh,
            Label = Extension.LoadString("AuthenticationLabel")
        ]
    ],
    Label = Extension.LoadString("DataSourceLabel")
];

EnforceSchema.Strict = 1;               // Add any missing columns, remove extra columns, set table type
EnforceSchema.IgnoreExtraColumns = 2;   // Add missing columns, do not remove extra columns
EnforceSchema.IgnoreMissingColumns = 3; // Do not add or remove columns

SchemaTransformTable = (table as table, schema as table, optional enforceSchema as number) as table =>
    let
        // Default to EnforceSchema.Strict
        _enforceSchema = if (enforceSchema <> null) then enforceSchema else EnforceSchema.Strict,

        // Applies type transforms to a given table
        EnforceTypes = (table as table, schema as table) as table =>
            let
                map = (t) => if Type.Is(t, type list) or Type.Is(t, type record) or t = type any then null else t,
                mapped = Table.TransformColumns(schema, {"Type", map}),
                omitted = Table.SelectRows(mapped, each [Type] <> null),
                existingColumns = Table.ColumnNames(table),
                removeMissing = Table.SelectRows(omitted, each List.Contains(existingColumns, [Name])),
                primativeTransforms = Table.ToRows(removeMissing),
                changedPrimatives = Table.TransformColumnTypes(table, primativeTransforms)
            in
                changedPrimatives,

        // Returns the table type for a given schema
        SchemaToTableType = (schema as table) as type =>
            let
                toList = List.Transform(schema[Type], (t) => [Type=t, Optional=false]),
                toRecord = Record.FromList(toList, schema[Name]),
                toType = Type.ForRecord(toRecord, false)
            in
                type table (toType),

        // Determine if we have extra/missing columns.
        // The enforceSchema parameter determines what we do about them.
        schemaNames = schema[Name],
        foundNames = Table.ColumnNames(table),
        addNames = List.RemoveItems(schemaNames, foundNames),
        extraNames = List.RemoveItems(foundNames, schemaNames),
        tmp = Text.NewGuid(),
        added = Table.AddColumn(table, tmp, each []),
        expanded = Table.ExpandRecordColumn(added, tmp, addNames),
        result = if List.IsEmpty(addNames) then table else expanded,
        fullList =
            if (_enforceSchema = EnforceSchema.Strict) then
                schemaNames
            else if (_enforceSchema = EnforceSchema.IgnoreMissingColumns) then
                foundNames
            else
                schemaNames & extraNames,

        // Select the final list of columns.
        // These will be ordered according to the schema table.
        reordered = Table.SelectColumns(result, fullList, MissingField.Ignore),
        enforcedTypes = EnforceTypes(reordered, schema),
        withType = if (_enforceSchema = EnforceSchema.Strict) then Value.ReplaceType(enforcedTypes, SchemaToTableType(schema)) else enforcedTypes
    in
        withType;

ExpandRows = (table as table, schema as table, includeRelations as logical, optional additionalFields as table) as table =>
    let
        schemaNames = schema[Name],
        expanded = if (Table.HasColumns(table, { "Column1" })) then Table.ExpandRecordColumn(table, "Column1", schemaNames) else table,
        expandedWithRelations = if (includeRelations and Table.HasColumns(expanded, { "Relations" })) then Table.ExpandListColumn(expanded, "Relations") else expanded,
        expandedWithRelationRecords = if (includeRelations and Table.HasColumns(expandedWithRelations, { "Relations" })) then Table.ExpandRecordColumn(expandedWithRelations, "Relations", RelationsSchema[OriginalName], RelationsSchema[Name]) else expandedWithRelations,
        schemaWithRelations = if (includeRelations and Table.HasColumns(expandedWithRelations, { "Relations" })) then InsertRelationFieldsToSchema(schema) else schema,
        expandedWithAdditionalFields = if (additionalFields = null or not Table.HasColumns(expandedWithRelations, { "AdditionalFields" })) then expandedWithRelationRecords else Table.ExpandRecordColumn(expandedWithRelationRecords, "AdditionalFields", GetAdditionalFieldNames(additionalFields)),
        schemaWithAdditionalFields = if (additionalFields = null or not Table.HasColumns(expandedWithRelations, { "AdditionalFields" })) then schemaWithRelations else InsertAdditionalFieldsToSchema(additionalFields, schemaWithRelations),
        data = SchemaTransformTable(expandedWithAdditionalFields, schemaWithAdditionalFields)
    in
        data;

FilterAdditionalFields = (additionalFields as table) as table =>
    let
        filtered = Table.SelectRows(additionalFields, each [Type] <> 8)
    in
        filtered;

GetAdditionalFieldNames = (additionalFields as table) as list =>
    let
        names = Table.TransformRows(additionalFields, each "af_" & Number.ToText([FieldId]))
    in
        names;

RelationsSchema = #table({"OriginalName", "Type", "Name"}, {
        {"DifferDirection", type logical, "Relations_DifferDirection"},
        {"ForeignFolderName", type text, "Relations_ForeignFolderName"},
        {"ForeignItemGUID", type text, "Relations_ForeignItemGUID"},
        {"ItemGUID", type text, "Relations_ItemGUID"},
        {"OwnerGUID", type text, "Relations_OwnerGUID"},
        {"RelationDataGUID", type text, "Relations_RelationDataGUID"},
        {"RelationType", type text, "Relation_sRelationType"}
    });

StandardFields = #table({"Name", "Type"}, {
    {"ItemGUID", type text},
    {"ItemVersion", type number},
    {"AdditionalFields", type text},
    {"Relations", type text},
    {"FileAs", type text},
    {"CreatedByGUID", type text},
    {"ItemChanged", type datetimezone},
    {"ItemCreated", type datetimezone},
    {"ModifiedByGUID", type text},
    {"OwnerGUID", type text},
    {"Server_ItemChanged", type datetimezone},
    {"Server_ItemCreated", type datetimezone},
    {"IsPrivate", type text}
});

SchemaTable = #table({"Entity", "SchemaTable"}, {
    {"AdditionalFields", #table({"Name", "Type"}, {
        {"ObjectTypeId", type number},
        {"ObjectTypeFolderName", type text},
        {"FieldId", type number},
        {"Name", type text},
        {"Type", type number},
        {"Rank", type number},
        {"CategoryEn", type text},
        {"Comment", type text},
        {"Data", type text},
        {"Data_RelatedFolderName", type text},
        {"Data_IsDateTime", type logical},
        {"Data_FormatType", type text},
        {"Data_EditMask", type text},
        {"Data_MemoBoxLines", type number},
        {"Data_SummaryType", type text},
        {"Data_LinkType", type text},
        {"AssociatedEnumTypeGuid", type text},
        {"IsInGeneralSection", type logical},
        {"ColumnName", type text}
    })},
    {"Calendars", #table({"Name", "Type"}, {
        {"Companies_TaskParentGuid", type text},
        {"Contacts_TaskParentGuid", type text},
        {"Leads_TaskParentGuid", type text},
        {"Projects_TaskParentGuid", type text},
        {"Marketing_TaskParentGuid", type text},
        {"Location", type text},
        {"StartDate", type datetimezone},
        {"EndDate", type datetimezone},
        {"IsAllDayEvent", type logical},
        {"Note", type text},
        {"BusyStatus", type number},
        {"Sensitivity", type number},
        {"BusyStatusEn", type text}
    })},
    {"Carts", #table({"Name", "Type"}, {
        {"Contacts_ContactPersonGuid", type text},
        {"Companies_CustomerGuid", type text},
        {"Leads_CartGuid", type text},
        {"Projects_CartGuid", type text},
        {"Id", type number},
        {"EffectiveFrom", type datetimezone},
        {"ValidUntil", type datetimezone},
        {"IsActive", type logical},
        {"TypeEn", type text},
        {"PriceTotal", type number},
        {"ForPayment", type number},
        {"Paid", type number},
        {"CurrencyEn", type text},
        {"Vat", type number},
        {"PriceTotalExcludingVat", type number},
        {"GoodsInCartCount", type number},
        {"Note", type text},
        {"PriceTotalDefaultCurrency", type number},
        {"PriceTotalParentCurrency", type number},
        {"ForPaymentDefaultCurrency", type number},
        {"ForPaymentParentCurrency", type number},
        {"PaidDefaultCurrency", type number},
        {"PaidParentCurrency", type number},
        {"PriceTotalExcludingVatDefaultCurrency", type number},
        {"PriceTotalExcludingVatParentCurrency", type number},
        {"VatDefaultCurrency", type number},
        {"VatParentCurrency", type number},
        {"PaidChanged", type datetimezone},
        {"PriceTotalChanged", type datetimezone},
        {"StateEn", type text},
        {"PrevStateEn", type text},
        {"TaxableSupplyDate", type datetimezone},
        {"AccountingCaseDate", type datetimezone},
        {"PaymentDate", type datetimezone},
        {"PurchaseExpenses", type number},
        {"PurchaseExpensesParentCurrency", type number},
        {"PurchaseExpensesDefaultCurrency", type number},
        {"PurchaseExpensesChanged", type datetimezone},
        {"Profit", type number},
        {"ProfitDefaultCurrency", type number},
        {"ProfitParentCurrency", type number},
        {"ProfitChanged", type datetimezone},
        {"IsToBeInvoiced", type logical},
        {"IsInvoiced", type logical},
        {"IsPaid", type logical},
        {"IsVoided", type logical},
        {"Picture", type text},
        {"PictureWidth", type number},
        {"PictureHeight", type number}
    })},
    {"Companies", #table({"Name", "Type"}, {
        {"AccountNumber", type text},
        {"Address1POBox", type text},
        {"Address1Street", type text},
        {"Address1City", type text},
        {"Address1State", type text},
        {"Address1CountryEn", type text},
        {"Address1PostalCode", type text},
        {"Address2POBox", type text},
        {"Address2Street", type text},
        {"Address2City", type text},
        {"Address2State", type text},
        {"Address2CountryEn", type text},
        {"Address2PostalCode", type text},
        {"Address3POBox", type text},
        {"Address3Street", type text},
        {"Address3City", type text},
        {"Address3State", type text},
        {"Address3CountryEn", type text},
        {"Address3PostalCode", type text},
        {"CompanyName", type text},
        {"Department", type text},
        {"Email", type text},
        {"EmployeesCount", type number},
        {"Fax", type text},
        {"FirstContactEn", type text},
        {"ICQ", type text},
        {"IdentificationNumber", type text},
        {"ImportanceEn", type text},
        {"LineOfBusiness", type text},
        {"MailingListOther", type logical},
        {"Mobile", type text},
        {"MobileNormalized", type text},
        {"MSN", type text},
        {"Note", type text},
        {"Phone", type text},
        {"PhoneNormalized", type text},
        {"Purchaser", type logical},
        {"Reversal", type number},
        {"Skype", type text},
        {"Suppliers", type logical},
        {"VATNumber", type text},
        {"WebPage", type text},
        {"AdditionalDiscount", type number},
        {"ID", type number},
        {"Competitor", type logical},
        {"SalePriceGuid", type text},
        {"NotificationByEmail", type logical},
        {"NotificationBy", type text},
        {"LastActivity", type datetimezone},
        {"NextStep", type datetimezone},
        {"EmailOptOut", type logical},
        {"TypeEn", type text},
        {"StateEn", type text},
        {"PrevStateEn", type text},
        {"Picture", type text},
        {"PictureWidth", type number},
        {"PictureHeight", type number}
    })},
    {"Contacts", #table({"Name", "Type"}, {
        {"Companies_CompanyGuid", type text},
        {"BusinessAddressStreet", type text},
        {"BusinessAddressCity", type text},
        {"BusinessAddressState", type text},
        {"BusinessAddressCountryEn", type text},
        {"BusinessAddressPOBox", type text},
        {"BusinessAddressPostalCode", type text},
        {"HomeAddressStreet", type text},
        {"HomeAddressCity", type text},
        {"HomeAddressState", type text},
        {"HomeAddressCountryEn", type text},
        {"HomeAddressPOBox", type text},
        {"HomeAddressPostalCode", type text},
        {"OtherAddressStreet", type text},
        {"OtherAddressCity", type text},
        {"OtherAddressState", type text},
        {"OtherAddressCountryEn", type text},
        {"OtherAddressPOBox", type text},
        {"OtherAddressPostalCode", type text},
        {"Company", type text},
        {"Email1Address", type text},
        {"Email2Address", type text},
        {"Email3Address", type text},
        {"FirstName", type text},
        {"ICQ", type text},
        {"ImportanceEn", type text},
        {"LastName", type text},
        {"MiddleName", type text},
        {"MSN", type text},
        {"Note", type text},
        {"PrefixEn", type text},
        {"SuffixEn", type text},
        {"Skype", type text},
        {"TelephoneNumber1", type text},
        {"TelephoneNumber2", type text},
        {"TelephoneNumber3", type text},
        {"TelephoneNumber4", type text},
        {"TelephoneNumber5", type text},
        {"TelephoneNumber6", type text},
        {"TelephoneNumber1Normalized", type text},
        {"TelephoneNumber2Normalized", type text},
        {"TelephoneNumber3Normalized", type text},
        {"TelephoneNumber4Normalized", type text},
        {"TelephoneNumber5Normalized", type text},
        {"TelephoneNumber6Normalized", type text},
        {"Department", type text},
        {"Title", type text},
        {"WebPage", type text},
        {"DoNotSendNewsletter", type logical},
        {"ProfilePicture", type text},
        {"ProfilePictureWidth", type number},
        {"ProfilePictureHeight", type number},
        {"LastActivity", type datetimezone},
        {"NextStep", type datetimezone},
        {"TypeEn", type text},
        {"StateEn", type text},
        {"PrevStateEn", type text}
    })},
    {"CurrencyExchangeRates", #table({"Name", "Type"}, {
        {"InputCurrencyEn", type text},
        {"OutputCurrencyEn", type text},
        {"Rate", type number},
        {"From", type datetimezone},
        {"To", type datetimezone},
        {"IsValid", type logical}
    })},
    {"Documents", #table({"Name", "Type"}, {
        {"Companies_CompanyGuid", type text},
        {"Contacts_ContactGuid", type text},
        {"Leads_SuperiorItemGuid", type text},
        {"Projects_SuperiorItemGuid", type text},
        {"Marketing_SuperiorItemGuid", type text},
        {"DocName", type text},
        {"Extension", type text},
        {"CreationTime", type datetimezone},
        {"LastWriteTime", type datetimezone},
        {"DocSize", type number},
        {"ImportanceEn", type text},
        {"TypeEn", type text},
        {"Note", type text},
        {"StateEn", type text},
        {"PrevStateEn", type text},
        {"Preview", type text},
        {"PreviewWidth", type number},
        {"PreviewHeight", type number},
        {"IsGdprRelevant", type logical}
    })},
    {"Emails", #table({"Name", "Type"}, {
        {"Leads_OutlookProjectGuid", type text},
        {"Projects_OutlookProjectGuid", type text},
        {"Marketing_OutlookProjectGuid", type text},
        {"Tasks_TaskOriginGuid", type text},
        {"Subject", type text},
        {"SenderEmailAddress", type text},
        {"SentOn", type datetimezone},
        {"ReceivedTime", type datetimezone},
        {"AttachmentsCount", type number},
        {"To", type text},
        {"Cc", type text},
        {"Note", type text},
        {"ImportanceEn", type text},
        {"Checksum", type number},
        {"MessageId", type text},
        {"Hash", type text},
        {"ConversationIndex", type text},
        {"EmailFileExtension", type text},
        {"SentMailGUID", type text},
        {"IsGdprRelevant", type logical},
        {"Picture", type text},
        {"PictureWidth", type number},
        {"PictureHeight", type number},
        {"TypeEn", type text},
        {"StateEn", type text},
        {"PrevStateEn", type text},
        {"Summary", type text},
        {"SentimentTone", type number},
        {"SentimentToneEn", type text}
    })},
    {"EnumTypes", #table({"Name", "Type"}, {
        {"AssociatedWorkflowModelGuid", type text},
        {"EnumName", type text},
        {"IsSystem", type logical},
        {"AllowEditVisibility", type logical},
        {"AllowEditLastActivity", type logical},
        {"RequireDefaultValue", type logical},
        {"NameEn", type text},
        {"NameCs", type text},
        {"NameDe", type text},
        {"NameRu", type text},
        {"NameSk", type text},
        {"NameNo", type text},
        {"IsAdditionalField", type logical},
        {"AssociatedAdditionalFieldId", type number},
        {"EditMode", type text}
    })},
    {"EnumValues", #table({"Name", "Type"}, {
        {"EnumType", type text},
        {"EnumTypeName", type text},
        {"Rank", type number},
        {"IsSystem", type logical},
        {"IsVisible", type logical},
        {"En", type text},
        {"Cs", type text},
        {"De", type text},
        {"Ru", type text},
        {"Sk", type text},
        {"No", type text},
        {"IncludeInLastActivityCalculation", type logical},
        {"IsDefault", type logical},
        {"PerformsLockItemAction", type logical},
        {"PerformsAreEqualAction", type logical},
        {"PerformsCheckRelationPresenceAction", type logical},
        {"PerformsWriteJournalAction", type logical},
        {"PerformsSetOwnerAction", type logical},
        {"PerformsSetFieldValueAction", type logical},
        {"PerformsCreateTaskAction", type logical},
        {"PerformsCreateRelationAction", type logical},
        {"PerformsSendEmailAction", type logical},
        {"SetOwnerActionMessage", type text},
        {"WriteJournalActionTitle", type text},
        {"WriteJournalActionTypeEn", type text},
        {"WriteJournalActionImportanceEn", type text},
        {"WriteJournalActionMessage", type text},
        {"ActionItemGuid", type text}
    })},
    {"EnumValuesRelations", #table({"Name", "Type"}, {

    })},
    {"Flows", #table({"Name", "Type"}, {
        {"ModelGuid", type text},
        {"PrecedentEn", type text},
        {"SuccedentEn", type text},
        {"Roundtrip", type logical},
        {"PerformsLockItemAction", type logical},
        {"PerformsAreEqualAction", type logical},
        {"PerformsCheckRelationPresenceAction", type logical},
        {"PerformsWriteJournalAction", type logical},
        {"PerformsSetOwnerAction", type logical},
        {"PerformsSetFieldValueAction", type logical},
        {"PerformsCreateTaskAction", type logical},
        {"PerformsCreateRelationAction", type logical},
        {"PerformsSendEmailAction", type logical},
        {"SetOwnerActionMessage", type text},
        {"WriteJournalActionTitle", type text},
        {"WriteJournalActionTypeEn", type text},
        {"WriteJournalActionImportanceEn", type text},
        {"WriteJournalActionMessage", type text},
        {"ActionItemGuid", type text}
    })},
    {"GlobalSettings", #table({"Name", "Type"}, {
        {"Name", type text},
        {"Value", type text},
        {"Type", type number},
        {"Visible", type logical},
        {"NameEn", type text},
        {"NameCs", type text},
        {"NameDe", type text},
        {"NameRu", type text},
        {"NameSk", type text},
        {"NameNo", type text},
        {"MinValue", type number},
        {"MaxValue", type number},
        {"EditMask", type text},
        {"Category", type text},
        {"IsLegacy", type logical},
        {"FeatureGuid", type text},
        {"Rank", type number},
        {"KbUrlShortCode", type text},
        {"DependsOn", type text},
        {"DependsOnValue", type text},
        {"UnlimitedValue", type text},
        {"DisabledValue", type text},
        {"DependsOnValueInverted", type logical}
    })},
    {"Goals", #table({"Name", "Type"}, {
        {"Users_GoalGuid", type text},
        {"TypeEn", type text},
        {"Note", type text},
        {"StartDate", type datetimezone},
        {"EndDate", type datetimezone},
        {"TurnoverGoal", type number},
        {"TurnoverActual", type number},
        {"TurnoverCompleted", type number},
        {"ProfitGoal", type number},
        {"ProfitActual", type number},
        {"ProfitCompleted", type number},
        {"CurrencyEn", type text},
        {"TurnoverGoalDefaultCurrency", type number},
        {"ProfitGoalDefaultCurrency", type number},
        {"TurnoverGoalChanged", type datetimezone},
        {"ProfitGoalChanged", type datetimezone},
        {"Picture", type text},
        {"PictureWidth", type number},
        {"PictureHeight", type number},
        {"StateEn", type text},
        {"PrevStateEn", type text}
    })},
    {"Goods", #table({"Name", "Type"}, {
        {"Goods_SuperiorGoodGuid", type text},
        {"Code", type text},
        {"SaleCurrencyEn", type text},
        {"PurchaseCurrencyEn", type text},
        {"UnitEn", type text},
        {"PurchasePrice", type number},
        {"SalePrice", type number},
        {"Note", type text},
        {"Structure", type text},
        {"PriceListGroupGuid", type text},
        {"IsPriceSum", type logical},
        {"Description", type text},
        {"InventoryQuantity", type number},
        {"SalePriceDefaultCurrency", type number},
        {"SalePriceChanged", type datetimezone},
        {"PurchasePriceDefaultCurrency", type number},
        {"PurchasePriceChanged", type datetimezone},
        {"VatRate", type number},
        {"VatIncluded", type logical},
        {"Picture", type text},
        {"PictureWidth", type number},
        {"PictureHeight", type number},
        {"TypeEn", type text},
        {"StateEn", type text},
        {"PrevStateEn", type text}
    })},
    {"GoodsInCart", #table({"Name", "Type"}, {
        {"Carts_GoodsInCartGuid", type text},
        {"Goods_GoodsInfoGuid", type text},
        {"Leads_ProjectGuid", type text},
        {"Projects_ProjectGuid", type text},
        {"Code", type text},
        {"SaleCurrencyEn", type text},
        {"PurchaseCurrencyEn", type text},
        {"UnitEn", type text},
        {"PurchasePrice", type number},
        {"SalePrice", type number},
        {"Quantity", type number},
        {"Note", type text},
        {"PriceTotal", type number},
        {"Structure", type text},
        {"ListPrice", type number},
        {"Discount", type number},
        {"HierarchyInSet", type text},
        {"IsFromSet", type logical},
        {"ParentGuid", type text},
        {"Rank", type number},
        {"IsPriceSum", type logical},
        {"IncludeInCartPrice", type logical},
        {"ListPriceCustomized", type logical},
        {"Description", type text},
        {"ChildItemsCount", type number},
        {"VatRate", type number},
        {"PriceTotalExcludingVat", type number},
        {"VatTotal", type number},
        {"SalePriceExcludingVat", type number},
        {"Vat", type number},
        {"PurchasePriceDefaultCurrency", type number},
        {"PurchasePriceParentCurrency", type number},
        {"SalePriceDefaultCurrency", type number},
        {"SalePriceParentCurrency", type number},
        {"PriceTotalDefaultCurrency", type number},
        {"PriceTotalParentCurrency", type number},
        {"ListPriceDefaultCurrency", type number},
        {"ListPriceParentCurrency", type number},
        {"PriceTotalExcludingVatDefaultCurrency", type number},
        {"PriceTotalExcludingVatParentCurrency", type number},
        {"VatTotalDefaultCurrency", type number},
        {"VatTotalParentCurrency", type number},
        {"SalePriceExcludingVatDefaultCurrency", type number},
        {"SalePriceExcludingVatParentCurrency", type number},
        {"VatDefaultCurrency", type number},
        {"VatParentCurrency", type number},
        {"JoinedToGuid", type text},
        {"PurchasePriceChanged", type datetimezone},
        {"SalePriceChanged", type datetimezone},
        {"PriceTotalChanged", type datetimezone},
        {"ListPriceChanged", type datetimezone},
        {"PurchasePriceTotal", type number},
        {"PurchasePriceTotalDefaultCurrency", type number},
        {"PurchasePriceTotalParentCurrency", type number},
        {"PurchasePriceTotalChanged", type datetimezone},
        {"VatIncluded", type logical},
        {"Picture", type text},
        {"PictureWidth", type number},
        {"PictureHeight", type number}
    })},
    {"Groups", #table({"Name", "Type"}, {
        {"Description", type text},
        {"DisallowControlModulePermissions", type logical},
        {"DisallowControlColumnPermissions", type logical},
        {"DisallowControlUserAssignment", type logical},
        {"IsAdmin", type logical},
        {"IsCategory", type logical},
        {"IsOutlookCategory", type logical},
        {"IsPM", type logical},
        {"IsRole", type logical},
        {"GroupName", type text},
        {"System", type logical},
        {"ResponsibilityDescription", type text},
        {"ContainsAnyUneditablePermission", type logical},
        {"Picture", type text},
        {"PictureWidth", type number},
        {"PictureHeight", type number},
        {"ColorEn", type text}
    })},
    {"Journals", #table({"Name", "Type"}, {
        {"Marketing_SuperiorItemGuid", type text},
        {"Companies_CompanyGuid", type text},
        {"Contacts_ContactGuid", type text},
        {"Leads_SuperiorItemGuid", type text},
        {"Projects_SuperiorItemGuid", type text},
        {"Marketing_MarketingGuid", type text},
        {"CalendarEntryID", type text},
        {"Calendar_ORIGIN", type text},
        {"ChangedField", type text},
        {"EventEnd", type datetimezone},
        {"EventStart", type datetimezone},
        {"FieldValue", type text},
        {"ImportanceEn", type text},
        {"Note", type text},
        {"PrevFieldValue", type text},
        {"TypeEn", type text},
        {"IsSystem", type logical},
        {"Phone", type text},
        {"PhoneNormalized", type text},
        {"IsGdprRelevant", type logical},
        {"Picture", type text},
        {"PictureWidth", type number},
        {"PictureHeight", type number},
        {"StateEn", type text},
        {"PrevStateEn", type text}
    })},
    {"Leads", #table({"Name", "Type"}, {
        {"Companies_CustomerGuid", type text},
        {"Contacts_ContactPersonGuid", type text},
        {"Marketing_MarketingGuid", type text},
        {"City", type text},
        {"ContactPerson", type text},
        {"CurrencyEn", type text},
        {"Customer", type text},
        {"Email", type text},
        {"EstimatedEnd", type datetimezone},
        {"HID", type number},
        {"LeadOriginEn", type text},
        {"Note", type text},
        {"Phone", type text},
        {"PhoneNormalized", type text},
        {"PrevStateEn", type text},
        {"Price", type number},
        {"PriceChanged", type datetimezone},
        {"PriceDefaultCurrency", type number},
        {"Probability", type number},
        {"ReceiveDate", type datetimezone},
        {"StateEn", type text},
        {"Street", type text},
        {"TypeEn", type text},
        {"Zip", type text},
        {"LastActivity", type datetimezone},
        {"NextStep", type datetimezone},
        {"EstimatedValue", type number},
        {"IsCompleted", type logical},
        {"IsLost", type logical},
        {"CountryEn", type text},
        {"State", type text},
        {"POBox", type text},
        {"EmailOptOut", type logical},
        {"Picture", type text},
        {"PictureWidth", type number},
        {"PictureHeight", type number},
        {"CompletedDate", type datetimezone},
        {"LostDate", type datetimezone}
    })},
    {"MarketingCampaigns", #table({"Name", "Type"}, {
        {"ID", type number},
        {"TypeEn", type text},
        {"StateEn", type text},
        {"EstimatedStart", type datetimezone},
        {"EstimatedEnd", type datetimezone},
        {"Budget", type number},
        {"EstimatedResponses", type number},
        {"EstimatedRevenues", type number},
        {"RealStart", type datetimezone},
        {"RealEnd", type datetimezone},
        {"Expenses", type number},
        {"FinalResponses", type number},
        {"FinalRevenues", type number},
        {"Note", type text},
        {"PrevStateEn", type text},
        {"EmailCampaignHash", type text},
        {"PeopleUnsubscribed", type number},
        {"TargetGroup", type number},
        {"EmailsSent", type number},
        {"EmailsDelivered", type number},
        {"EmailsViewed", type number},
        {"EmailCampaignContactListChanged", type logical},
        {"EmailsMarkedAsSpam", type number},
        {"EmailCampaignEmailSent", type datetimezone},
        {"LastResponsesDownloadTime", type datetimezone},
        {"ResponsesDownloadCount", type number},
        {"Picture", type text},
        {"PictureWidth", type number},
        {"PictureHeight", type number}
    })},
    {"MarketingListsRecords", #table({"Name", "Type"}, {
        {"Contact", type text},
        {"Company", type text},
        {"Email1Address", type text},
        {"Phone", type text},
        {"MarketingCampaignGuid", type text},
        {"AddressStreet", type text},
        {"AddressPostalCode", type text},
        {"AddressCity", type text},
        {"FolderName", type text},
        {"FirstName", type text},
        {"LastName", type text},
        {"LeadGuid", type text},
        {"ContactGuid", type text},
        {"CompanyGuid", type text}
    })},
    {"Projects", #table({"Name", "Type"}, {
        {"Companies_CustomerGuid", type text},
        {"Contacts_ContactPersonGuid", type text},
        {"Leads_Project_OriginGuid", type text},
        {"Projects_SuperiorProjectGuid", type text},
        {"Users_SupervisorGuid", type text},
        {"Note", type text},
        {"Price", type number},
        {"ProjectEnd", type datetimezone},
        {"ProjectName", type text},
        {"TypeEn", type text},
        {"StateEn", type text},
        {"PeopleExpenses", type number},
        {"ProjectRealEnd", type datetimezone},
        {"EstimatedPrice", type number},
        {"HID", type number},
        {"ProjectOriginEn", type text},
        {"PaymentTypeEn", type text},
        {"OtherExpenses", type number},
        {"Margin", type number},
        {"Profit", type number},
        {"PaymentMaturity", type number},
        {"InvoicePaymentDate", type datetimezone},
        {"InvoiceIssueDate", type datetimezone},
        {"EstimatedMargin", type number},
        {"EstimatedProfit", type number},
        {"EstimatedPeopleExpenses", type number},
        {"EstimatedOtherExpenses", type number},
        {"LicensesCount", type number},
        {"LicensePrice", type number},
        {"PrevStateEn", type text},
        {"ShowInCaplan", type logical},
        {"ProjectStart", type datetimezone},
        {"EstimatedWorkHours", type number},
        {"TotalWorkHours", type number},
        {"EstimatedPeopleExpensesDefaultCurrency", type number},
        {"EstimatedOtherExpensesDefaultCurrency", type number},
        {"EstimatedPriceDefaultCurrency", type number},
        {"PeopleExpensesDefaultCurrency", type number},
        {"OtherExpensesDefaultCurrency", type number},
        {"PriceDefaultCurrency", type number},
        {"ProfitDefaultCurrency", type number},
        {"EstimatedProfitDefaultCurrency", type number},
        {"CurrencyEn", type text},
        {"EstimatedPeopleExpensesChanged", type datetimezone},
        {"EstimatedOtherExpensesChanged", type datetimezone},
        {"OtherExpensesChanged", type datetimezone},
        {"EstimatedPriceChanged", type datetimezone},
        {"PriceChanged", type datetimezone},
        {"LicensePriceChanged", type datetimezone},
        {"LicensePriceDefaultCurrency", type number},
        {"LastActivity", type datetimezone},
        {"NextStep", type datetimezone},
        {"CompletedDate", type datetimezone},
        {"IsCompleted", type logical},
        {"LostDate", type datetimezone},
        {"IsLost", type logical},
        {"PeopleExpensesChanged", type datetimezone},
        {"Picture", type text},
        {"PictureWidth", type number},
        {"PictureHeight", type number}
    })},
    {"RecurrencePatterns", #table({"Name", "Type"}, {
        {"TaskGuid", type text},
        {"RecurrenceType", type number},
        {"Interval", type number},
        {"Instance", type number},
        {"DayOfWeekMask", type number},
        {"DayOfMonth", type number},
        {"MonthOfYear", type number},
        {"Regenerate", type logical},
        {"NoEndDate", type logical},
        {"Occurrences", type number},
        {"PatternStartDate", type datetimezone},
        {"PatternEndDate", type datetimezone},
        {"EndKind", type number}
    })},
    {"SalePrices", #table({"Name", "Type"}, {
        {"Note", type text},
        {"Discount", type number},
        {"Picture", type text},
        {"PictureWidth", type number},
        {"PictureHeight", type number},
        {"TypeEn", type text},
        {"StateEn", type text},
        {"PrevStateEn", type text}
    })},
    {"Tasks", #table({"Name", "Type"}, {
        {"Leads_TopLevelProjectGuid", type text},
        {"Leads_TaskParentGuid", type text},
        {"Projects_TopLevelProjectGuid", type text},
        {"Projects_TaskParentGuid", type text},
        {"Tasks_TaskParentGuid", type text},
        {"Marketing_TopLevelProjectGuid", type text},
        {"Marketing_TaskParentGuid", type text},
        {"Companies_CompanyGuid", type text},
        {"Contacts_ContactGuid", type text},
        {"Users_TaskDelegatorGuid", type text},
        {"Users_TaskSolverGuid", type text},
        {"Tasks_TaskOriginGuid", type text},
        {"Body", type text},
        {"IsCompleted", type logical},
        {"DueDate", type datetimezone},
        {"PercentCompleteDecimal", type number},
        {"PrevStateEn", type text},
        {"StartDate", type datetimezone},
        {"StateEn", type text},
        {"Subject", type text},
        {"TypeEn", type text},
        {"Level", type number},
        {"ImportanceEn", type text},
        {"ActualWorkHours", type number},
        {"EstimatedWorkHours", type number},
        {"IsReminderSet", type logical},
        {"ReminderDate", type datetimezone},
        {"CompletedDate", type datetimezone},
        {"Picture", type text},
        {"PictureWidth", type number},
        {"PictureHeight", type number}
    })},
    {"Users", #table({"Name", "Type"}, {
        {"Users_SupervisorGuid", type text},
        {"Groups_Default_GroupGuid", type text},
        {"Username", type text},
        {"FirstName", type text},
        {"MiddleName", type text},
        {"LastName", type text},
        {"IsActive", type logical},
        {"MobilePhoneNumber", type text},
        {"BusinessPhoneNumber", type text},
        {"MobilePhoneNumberNormalized", type text},
        {"BusinessPhoneNumberNormalized", type text},
        {"Email1Address", type text},
        {"Email2Address", type text},
        {"HomeAddressStreet", type text},
        {"HomeAddressCity", type text},
        {"HomeAddressPostalCode", type text},
        {"HomeAddressState", type text},
        {"HomeAddressPOBox", type text},
        {"HomeAddressCountryEn", type text},
        {"BankAccount", type text},
        {"BirthPlace", type text},
        {"Note", type text},
        {"IDCardNumber", type text},
        {"Birthdate", type datetimezone},
        {"IdentificationNumber", type text},
        {"HealthInsurance", type text},
        {"HolidayLength", type number},
        {"PersonalIdentificationNumber", type text},
        {"MSN", type text},
        {"ICQ", type text},
        {"Skype", type text},
        {"FamilyStatusEn", type text},
        {"SalaryDateEn", type text},
        {"TransportMode", type text},
        {"TravelDistance", type text},
        {"TimeAccessibility", type text},
        {"IsHRManager", type logical},
        {"IsProjectManager", type logical},
        {"PrefixEn", type text},
        {"SuffixEn", type text},
        {"WorkdayStartTime", type text},
        {"RemainingDaysOfHoliday", type number},
        {"IsSystem", type logical},
        {"IsApiUser", type logical},
        {"JobTitle", type text},
        {"ProfilePicture", type text},
        {"ProfilePictureWidth", type number},
        {"ProfilePictureHeight", type number},
        {"Server_Password", type text},
        {"Server_OutlookAccess", type logical},
        {"Server_WebAccess", type logical},
        {"Server_MobileAccess", type logical},
        {"Server_LastLogin", type datetimezone},
        {"Server_LastActivity", type datetimezone},
        {"Server_AccountLockedTime", type datetimezone},
        {"Server_ForcePasswordChange", type logical},
        {"Server_IsAccountLocked", type logical},
        {"TypeEn", type text},
        {"StateEn", type text},
        {"PrevStateEn", type text}
    })},
    {"UserSettings", #table({"Name", "Type"}, {
        {"Name", type text},
        {"Value", type text},
        {"Path", type text}
    })},
    {"WorkflowHistoryRecords", #table({"Name", "Type"}, {
        {"PrecedentEn", type text},
        {"SuccedentEn", type text},
        {"RelatedItemGuid", type text},
        {"RelatedItemFolderName", type text}
    })},
    {"WorkflowModels", #table({"Name", "Type"}, {
        {"EnumTypeGuid", type text},
        {"ParentEn", type text},
        {"IsSystem", type logical},
        {"IsUsingFlows", type logical},
        {"AllowEditItems", type logical}
    })},
    {"WorkReports", #table({"Name", "Type"}, {
        {"Leads_LeadGuid", type text},
        {"Users_PersonGuid", type text},
        {"Tasks_TaskGuid", type text},
        {"Leads_ProjectGuid", type text},
        {"Projects_ProjectGuid", type text},
        {"Subject", type text},
        {"From", type datetimezone},
        {"To", type datetimezone},
        {"Duration", type number},
        {"Note", type text},
        {"Rate", type number},
        {"TypeEn", type text},
        {"ImportanceEn", type text},
        {"DayTypeEn", type text},
        {"Overtime", type logical},
        {"CalendarOrigin", type text},
        {"Year", type number},
        {"Month", type number},
        {"CalendarEntryId", type text},
        {"RateDefaultCurrency", type number},
        {"RateParentCurrency", type number},
        {"CurrencyEn", type text},
        {"StateEn", type text},
        {"PrevStateEn", type text},
        {"RateAdditional", type number},
        {"RateAdditionalDefaultCurrency", type number},
        {"RateAdditionalParentCurrency", type number},
        {"Picture", type text},
        {"PictureWidth", type number},
        {"PictureHeight", type number}
    })}
});

GetSchemaForEntity = (entity as text) as table => try SchemaTable{[Entity=entity]}[SchemaTable] otherwise error "Couldn't find entity: '" & entity &"'";

InsertAdditionalFieldsToSchema = (additionalFields as table, schema as table) as table =>
    let
        filteredSchema = Table.SelectRows(schema, each [Name] <> "AdditionalFields"),
        table = Table.InsertRows(filteredSchema, 0, Table.TransformRows(additionalFields, (row) as record => [Name = "af_" & Number.ToText(row[FieldId]), Type = GetAdditionalFieldType(row[Type])]))
    in
        table;

InsertRelationFieldsToSchema = (schema as table) as table =>
    let
        filteredSchema = Table.SelectRows(schema, each [Name] <> "Relations"),
        table = Table.InsertRows(filteredSchema, 0, Table.TransformRows(RelationsSchema, (row) as record => [Name = row[Name], Type = row[Type]]))
    in
        table;

InsertStandardFieldsToSchema = (schema as table) as table =>
    let
        table = Table.InsertRows(schema, 0, Table.TransformRows(StandardFields, (row) as record => [Name = row[Name], Type = row[Type]]))
    in
        table;

GetAdditionalFieldType = (fieldType as number) as type =>
    let
        tableType = if (fieldType) = 2 then type number else
            if (fieldType) = 4 then type logical else
            if (fieldType) = 6 then type datetimezone
            else type text
    in
        tableType;

// Data Source UI publishing description
eWayCRM.Publish = [
    Beta = false,
    Category = "Online Services",
    ButtonText = { Extension.LoadString("ButtonTitle"), Extension.LoadString("ButtonHelp") },
    LearnMoreUrl = "https://www.eway-crm.com/",
    SourceImage = eWayCRM.Icons,
    SourceTypeImage = eWayCRM.Icons
];

eWayCRM.Icons = [
    Icon16 = { Extension.Contents("eWay_CRM16.png"), Extension.Contents("eWay_CRM20.png"), Extension.Contents("eWay_CRM24.png"), Extension.Contents("eWay_CRM32.png") },
    Icon32 = { Extension.Contents("eWay_CRM32.png"), Extension.Contents("eWay_CRM40.png"), Extension.Contents("eWay_CRM48.png"), Extension.Contents("eWay_CRM64.png") }
];
