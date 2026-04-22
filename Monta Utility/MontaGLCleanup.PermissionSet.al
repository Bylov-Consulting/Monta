permissionset 90002 "Monta GL Cleanup"
{
    Caption = 'Monta: Clear Additional Reporting Amounts on G/L Entries';
    Assignable = true;

    Permissions =
        codeunit "Clear Add. Reporting Mgmt." = X,
        report "Clear Add. Reporting Amounts" = X,
        tabledata "G/L Entry" = RM;
}
