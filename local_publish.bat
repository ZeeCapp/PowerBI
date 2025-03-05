IF NOT EXIST "%USERPROFILE%\Documents\Power BI Desktop\Custom Connectors" MKDIR "%USERPROFILE%\Documents\Power BI Desktop\Custom Connectors"
COPY %~dp0bin\Debug\eWay_CRM.mez "%USERPROFILE%\Documents\Power BI Desktop\Custom Connectors"
COPY %~dp0bin\Debug\eWay_CRM.mez "C:\Windows\ServiceProfiles\PBIEgwService\Documents\Power BI Desktop\Custom Connectors"
PAUSE