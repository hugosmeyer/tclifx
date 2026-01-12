/*
 * ifxcli.c - Direct Informix CLI extension for Tcl
 * Provides native Informix database access without TclODBC
 * 
 * Compile with:
 * gcc -shared -fPIC -o libifxcli.so ifxcli.c \
 *     -I/usr/include -I/home/hugo/ifx/incl/cli \
 *     -L/home/hugo/ifx/lib/cli -lifcli \
 *     -ltcl8.6
 *
 * Or use the provided Makefile
 */

#include <tcl.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>

/* Define GUID type before including SQL headers */
#ifndef GUID_DEFINED
#define GUID_DEFINED
typedef struct {
    unsigned long  Data1;
    unsigned short Data2;
    unsigned short Data3;
    unsigned char  Data4[8];
} GUID;
#endif

#include <sql.h>
#include <sqlext.h>

/* Connection structure */
typedef struct {
    SQLHENV henv;
    SQLHDBC hdbc;
    int connected;
} IfxConnection;

/* Result set structure */
typedef struct {
    SQLHSTMT hstmt;
    SQLSMALLINT num_cols;
    char **col_names;
} IfxResultSet;

/* DSN configuration structure */
typedef struct {
    char driver[512];
    char database[256];
    char server[256];
    char host[256];
    char service[64];
    char protocol[64];
    char user[256];
    char password[256];
} DsnConfig;

/* Read DSN configuration from odbc.ini
 * 
 * Respects standard ODBC environment variables:
 *   ODBCINI     - Path to user's odbc.ini file (default: ~/.odbc.ini)
 *   ODBCSYSINI  - Directory containing system odbc.ini (default: /etc)
 * 
 * Search order:
 *   1. $ODBCINI (if set)
 *   2. ~/.odbc.ini
 *   3. $ODBCSYSINI/odbc.ini
 *   4. /etc/odbc.ini
 */
static int read_odbc_ini(const char *dsn, DsnConfig *config) {
    FILE *fp;
    char ini_paths[4][512];
    int num_paths = 0;
    char line[1024];
    int in_section = 0;
    int found = 0;
    
    /* Initialize config */
    memset(config, 0, sizeof(DsnConfig));
    
    /* Build list of odbc.ini paths to try */
    
    /* 1. ODBCINI environment variable (highest priority) */
    const char *odbcini = getenv("ODBCINI");
    if (odbcini && odbcini[0]) {
        snprintf(ini_paths[num_paths++], sizeof(ini_paths[0]), "%s", odbcini);
    }
    
    /* 2. User's home directory */
    const char *home = getenv("HOME");
    if (home && home[0]) {
        snprintf(ini_paths[num_paths++], sizeof(ini_paths[0]), "%s/.odbc.ini", home);
    }
    
    /* 3. ODBCSYSINI directory */
    const char *odbcsysini = getenv("ODBCSYSINI");
    if (odbcsysini && odbcsysini[0]) {
        snprintf(ini_paths[num_paths++], sizeof(ini_paths[0]), "%s/odbc.ini", odbcsysini);
    }
    
    /* 4. Default system location */
    snprintf(ini_paths[num_paths++], sizeof(ini_paths[0]), "/etc/odbc.ini");
    
    /* Try each ini file */
    for (int i = 0; i < num_paths; i++) {
        fp = fopen(ini_paths[i], "r");
        if (!fp) continue;
        
        in_section = 0;
        while (fgets(line, sizeof(line), fp)) {
            char *p = line;
            
            /* Trim whitespace */
            while (*p == ' ' || *p == '\t') p++;
            
            /* Skip comments and empty lines */
            if (*p == '#' || *p == ';' || *p == '\n' || *p == '\0') continue;
            
            /* Check for section header */
            if (*p == '[') {
                char section[256];
                if (sscanf(p, "[%255[^]]]", section) == 1) {
                    in_section = (strcmp(section, dsn) == 0);
                }
                continue;
            }
            
            /* Parse key=value in our section */
            if (in_section) {
                char key[256], value[512];
                char *eq = strchr(p, '=');
                if (eq) {
                    *eq = '\0';
                    
                    /* Copy key and trim */
                    strncpy(key, p, sizeof(key)-1);
                    key[sizeof(key)-1] = '\0';
                    char *k = key + strlen(key) - 1;
                    while (k >= key && (*k == ' ' || *k == '\t')) *k-- = '\0';
                    
                    /* Copy value and trim */
                    strncpy(value, eq+1, sizeof(value)-1);
                    value[sizeof(value)-1] = '\0';
                    char *v = value;
                    while (*v == ' ' || *v == '\t') v++;
                    char *vend = v + strlen(v) - 1;
                    while (vend >= v && (*vend == ' ' || *vend == '\t' || *vend == '\n')) *vend-- = '\0';
                    
                    /* Store values */
                    if (strcasecmp(key, "driver") == 0) {
                        snprintf(config->driver, sizeof(config->driver), "%s", v);
                        found = 1;
                    }
                    else if (strcasecmp(key, "database") == 0) {
                        snprintf(config->database, sizeof(config->database), "%s", v);
                    }
                    else if (strcasecmp(key, "server") == 0 || strcasecmp(key, "servername") == 0) {
                        snprintf(config->server, sizeof(config->server), "%s", v);
                    }
                    else if (strcasecmp(key, "host") == 0) {
                        snprintf(config->host, sizeof(config->host), "%s", v);
                    }
                    else if (strcasecmp(key, "service") == 0 || strcasecmp(key, "port") == 0) {
                        snprintf(config->service, sizeof(config->service), "%s", v);
                    }
                    else if (strcasecmp(key, "protocol") == 0) {
                        snprintf(config->protocol, sizeof(config->protocol), "%s", v);
                    }
                    else if (strcasecmp(key, "uid") == 0 || strcasecmp(key, "logonid") == 0) {
                        snprintf(config->user, sizeof(config->user), "%s", v);
                    }
                    else if (strcasecmp(key, "pwd") == 0 || strcasecmp(key, "password") == 0) {
                        snprintf(config->password, sizeof(config->password), "%s", v);
                    }
                }
            }
        }
        
        fclose(fp);
        if (found) return 1;
    }
    
    return 0;
}

/* Build connection string from DSN config */
static void build_connection_string(const DsnConfig *config, const char *dsn,
                                     const char *user, const char *password,
                                     char *conn_str, int bufsize) {
    int len = 0;
    
    /* Start with DSN */
    len += snprintf(conn_str + len, bufsize - len, "DSN=%s;", dsn);
    
    /* Add database */
    if (config->database[0]) {
        len += snprintf(conn_str + len, bufsize - len, "DATABASE=%s;", config->database);
    }
    
    /* Add server info */
    if (config->host[0]) {
        len += snprintf(conn_str + len, bufsize - len, "HOST=%s;", config->host);
    }
    if (config->server[0]) {
        len += snprintf(conn_str + len, bufsize - len, "SERVER=%s;", config->server);
    }
    if (config->service[0]) {
        len += snprintf(conn_str + len, bufsize - len, "SERVICE=%s;", config->service);
    }
    if (config->protocol[0]) {
        len += snprintf(conn_str + len, bufsize - len, "PROTOCOL=%s;", config->protocol);
    }
    
    /* Add credentials */
    if (user && user[0]) {
        len += snprintf(conn_str + len, bufsize - len, "UID=%s;", user);
    } else if (config->user[0]) {
        len += snprintf(conn_str + len, bufsize - len, "UID=%s;", config->user);
    }
    
    if (password && password[0]) {
        len += snprintf(conn_str + len, bufsize - len, "PWD=%s;", password);
    } else if (config->password[0]) {
        len += snprintf(conn_str + len, bufsize - len, "PWD=%s;", config->password);
    }
}

/* ifx::connect dsn ?user? ?password? */
static int IfxConnect_Cmd(ClientData clientData, Tcl_Interp *interp, 
                          int objc, Tcl_Obj *CONST objv[]) {
    IfxConnection *conn;
    SQLRETURN ret;
    char *dsn, *user = "", *password = "";
    DsnConfig config;
    char conn_str[2048];
    SQLCHAR out_conn_str[1024];
    SQLSMALLINT out_conn_len;
    char conn_name[64];
    static int conn_counter = 0;
    
    if (objc < 2 || objc > 4) {
        Tcl_WrongNumArgs(interp, 1, objv, "dsn ?user? ?password?");
        return TCL_ERROR;
    }
    
    dsn = Tcl_GetString(objv[1]);
    
    /* Read DSN configuration from odbc.ini */
    if (!read_odbc_ini(dsn, &config)) {
        /* DSN not found, use minimal connection string */
        memset(&config, 0, sizeof(config));
    }
    
    /* Get user/password from arguments if provided */
    if (objc >= 3) {
        user = Tcl_GetString(objv[2]);
    }
    if (objc >= 4) {
        password = Tcl_GetString(objv[3]);
    }
    
    /* Build full connection string */
    build_connection_string(&config, dsn, user, password, conn_str, sizeof(conn_str));
    
    /* Allocate connection structure */
    conn = (IfxConnection *)ckalloc(sizeof(IfxConnection));
    conn->connected = 0;
    
    /* Allocate environment handle */
    ret = SQLAllocHandle(SQL_HANDLE_ENV, SQL_NULL_HANDLE, &conn->henv);
    if (ret != SQL_SUCCESS) {
        ckfree((char *)conn);
        Tcl_SetResult(interp, "Failed to allocate environment handle", TCL_STATIC);
        return TCL_ERROR;
    }
    
    /* Set ODBC version */
    SQLSetEnvAttr(conn->henv, SQL_ATTR_ODBC_VERSION, (SQLPOINTER)SQL_OV_ODBC3, 0);
    
    /* Allocate connection handle */
    ret = SQLAllocHandle(SQL_HANDLE_DBC, conn->henv, &conn->hdbc);
    if (ret != SQL_SUCCESS) {
        SQLFreeHandle(SQL_HANDLE_ENV, conn->henv);
        ckfree((char *)conn);
        Tcl_SetResult(interp, "Failed to allocate connection handle", TCL_STATIC);
        return TCL_ERROR;
    }
    
    /* Set connection timeout to avoid infinite hangs */
    SQLSetConnectAttr(conn->hdbc, SQL_ATTR_CONNECTION_TIMEOUT, (SQLPOINTER)30, 0);
    SQLSetConnectAttr(conn->hdbc, SQL_ATTR_LOGIN_TIMEOUT, (SQLPOINTER)30, 0);
    
    /* Connect using SQLDriverConnect with full connection string */
    ret = SQLDriverConnect(conn->hdbc, NULL,
                           (SQLCHAR *)conn_str, SQL_NTS,
                           out_conn_str, sizeof(out_conn_str),
                           &out_conn_len, SQL_DRIVER_NOPROMPT);
    
    if (ret != SQL_SUCCESS && ret != SQL_SUCCESS_WITH_INFO) {
        /* Get detailed error message */
        SQLCHAR sqlstate[6], errmsg[1024];
        SQLINTEGER native_error;
        SQLSMALLINT errmsg_len;
        char error_buf[1200];
        
        SQLGetDiagRec(SQL_HANDLE_DBC, conn->hdbc, 1, 
                      sqlstate, &native_error, errmsg, sizeof(errmsg), &errmsg_len);
        
        snprintf(error_buf, sizeof(error_buf), 
                 "Failed to connect: [%s] %s", sqlstate, errmsg);
        
        SQLFreeHandle(SQL_HANDLE_DBC, conn->hdbc);
        SQLFreeHandle(SQL_HANDLE_ENV, conn->henv);
        ckfree((char *)conn);
        Tcl_SetResult(interp, error_buf, TCL_VOLATILE);
        return TCL_ERROR;
    }
    
    conn->connected = 1;
    
    /* Create connection handle name */
    snprintf(conn_name, sizeof(conn_name), "ifxconn%d", ++conn_counter);
    
    /* Store connection in interpreter */
    Tcl_SetAssocData(interp, conn_name, NULL, (ClientData)conn);
    
    Tcl_SetResult(interp, conn_name, TCL_VOLATILE);
    return TCL_OK;
}

/* ifx::execute conn_handle sql ?param1 param2 ...? */
static int IfxExecute_Cmd(ClientData clientData, Tcl_Interp *interp,
                          int objc, Tcl_Obj *CONST objv[]) {
    IfxConnection *conn;
    IfxResultSet *result;
    SQLHSTMT hstmt;
    SQLRETURN ret;
    char *conn_name, *sql;
    char result_name[64];
    static int result_counter = 0;
    
    if (objc < 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "conn_handle sql ?params?");
        return TCL_ERROR;
    }
    
    conn_name = Tcl_GetString(objv[1]);
    sql = Tcl_GetString(objv[2]);
    
    /* Get connection */
    conn = (IfxConnection *)Tcl_GetAssocData(interp, conn_name, NULL);
    if (!conn || !conn->connected) {
        Tcl_SetResult(interp, "Invalid connection handle", TCL_STATIC);
        return TCL_ERROR;
    }
    
    /* Allocate statement handle */
    ret = SQLAllocHandle(SQL_HANDLE_STMT, conn->hdbc, &hstmt);
    if (ret != SQL_SUCCESS) {
        Tcl_SetResult(interp, "Failed to allocate statement handle", TCL_STATIC);
        return TCL_ERROR;
    }
    
    /* Execute SQL */
    ret = SQLExecDirect(hstmt, (SQLCHAR *)sql, SQL_NTS);
    /* SQL_NO_DATA (100) is returned for DELETE/UPDATE that affect 0 rows - not an error */
    if (ret != SQL_SUCCESS && ret != SQL_SUCCESS_WITH_INFO && ret != SQL_NO_DATA) {
        /* Get detailed error message from the database */
        SQLCHAR sqlstate[6] = "00000";
        SQLCHAR errmsg[1024] = "";
        SQLINTEGER native_error = 0;
        SQLSMALLINT errmsg_len = 0;
        char error_buf[1200];
        SQLRETURN diag_ret;
        
        diag_ret = SQLGetDiagRec(SQL_HANDLE_STMT, hstmt, 1, 
                      sqlstate, &native_error, errmsg, sizeof(errmsg), &errmsg_len);
        
        if (diag_ret == SQL_SUCCESS || diag_ret == SQL_SUCCESS_WITH_INFO) {
            snprintf(error_buf, sizeof(error_buf), 
                     "SQL error [%s] (%d): %s", sqlstate, (int)native_error, errmsg);
        } else {
            snprintf(error_buf, sizeof(error_buf), 
                     "SQL execution failed (ret=%d, no diagnostic available)", (int)ret);
        }
        
        SQLFreeHandle(SQL_HANDLE_STMT, hstmt);
        Tcl_SetResult(interp, error_buf, TCL_VOLATILE);
        return TCL_ERROR;
    }
    
    /* Create result set structure */
    result = (IfxResultSet *)ckalloc(sizeof(IfxResultSet));
    result->hstmt = hstmt;
    
    /* Get number of columns */
    SQLNumResultCols(hstmt, &result->num_cols);
    
    /* Get column names */
    result->col_names = (char **)ckalloc(result->num_cols * sizeof(char *));
    for (int i = 0; i < result->num_cols; i++) {
        SQLCHAR col_name[256];
        SQLSMALLINT name_len;
        
        SQLDescribeCol(hstmt, i+1, col_name, sizeof(col_name), &name_len,
                      NULL, NULL, NULL, NULL);
        
        result->col_names[i] = (char *)ckalloc(name_len + 1);
        strcpy(result->col_names[i], (char *)col_name);
    }
    
    /* Create result handle name */
    snprintf(result_name, sizeof(result_name), "ifxresult%d", ++result_counter);
    
    /* Store result in interpreter */
    Tcl_SetAssocData(interp, result_name, NULL, (ClientData)result);
    
    Tcl_SetResult(interp, result_name, TCL_VOLATILE);
    return TCL_OK;
}

/* ifx::fetch result_handle */
static int IfxFetch_Cmd(ClientData clientData, Tcl_Interp *interp,
                        int objc, Tcl_Obj *CONST objv[]) {
    IfxResultSet *result;
    char *result_name;
    SQLRETURN ret;
    Tcl_Obj *row_dict;
    
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "result_handle");
        return TCL_ERROR;
    }
    
    result_name = Tcl_GetString(objv[1]);
    
    /* Get result set */
    result = (IfxResultSet *)Tcl_GetAssocData(interp, result_name, NULL);
    if (!result) {
        Tcl_SetResult(interp, "Invalid result handle", TCL_STATIC);
        return TCL_ERROR;
    }
    
    /* Fetch next row */
    ret = SQLFetch(result->hstmt);
    
    if (ret == SQL_NO_DATA) {
        /* No more data */
        Tcl_SetResult(interp, "", TCL_STATIC);
        return TCL_OK;
    }
    
    if (ret != SQL_SUCCESS && ret != SQL_SUCCESS_WITH_INFO) {
        Tcl_SetResult(interp, "Fetch failed", TCL_STATIC);
        return TCL_ERROR;
    }
    
    /* Build dictionary with column names and values */
    row_dict = Tcl_NewDictObj();
    
    for (int i = 0; i < result->num_cols; i++) {
        SQLCHAR buffer[4096];
        SQLLEN indicator;
        
        ret = SQLGetData(result->hstmt, i+1, SQL_C_CHAR, buffer, 
                        sizeof(buffer), &indicator);
        
        if (ret == SQL_SUCCESS) {
            if (indicator == SQL_NULL_DATA) {
                Tcl_DictObjPut(interp, row_dict,
                              Tcl_NewStringObj(result->col_names[i], -1),
                              Tcl_NewObj());
            } else {
                Tcl_DictObjPut(interp, row_dict,
                              Tcl_NewStringObj(result->col_names[i], -1),
                              Tcl_NewStringObj((char *)buffer, -1));
            }
        }
    }
    
    Tcl_SetObjResult(interp, row_dict);
    return TCL_OK;
}

/* ifx::close_result result_handle */
static int IfxCloseResult_Cmd(ClientData clientData, Tcl_Interp *interp,
                              int objc, Tcl_Obj *CONST objv[]) {
    IfxResultSet *result;
    char *result_name;
    
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "result_handle");
        return TCL_ERROR;
    }
    
    result_name = Tcl_GetString(objv[1]);
    
    result = (IfxResultSet *)Tcl_GetAssocData(interp, result_name, NULL);
    if (result) {
        SQLFreeHandle(SQL_HANDLE_STMT, result->hstmt);
        
        for (int i = 0; i < result->num_cols; i++) {
            ckfree(result->col_names[i]);
        }
        ckfree((char *)result->col_names);
        ckfree((char *)result);
        
        Tcl_DeleteAssocData(interp, result_name);
    }
    
    return TCL_OK;
}

/* ifx::disconnect conn_handle */
static int IfxDisconnect_Cmd(ClientData clientData, Tcl_Interp *interp,
                             int objc, Tcl_Obj *CONST objv[]) {
    IfxConnection *conn;
    char *conn_name;
    
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "conn_handle");
        return TCL_ERROR;
    }
    
    conn_name = Tcl_GetString(objv[1]);
    
    conn = (IfxConnection *)Tcl_GetAssocData(interp, conn_name, NULL);
    if (conn) {
        if (conn->connected) {
            SQLDisconnect(conn->hdbc);
        }
        SQLFreeHandle(SQL_HANDLE_DBC, conn->hdbc);
        SQLFreeHandle(SQL_HANDLE_ENV, conn->henv);
        ckfree((char *)conn);
        
        Tcl_DeleteAssocData(interp, conn_name);
    }
    
    return TCL_OK;
}

/* Package initialization */
int Ifxcli_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) {
        return TCL_ERROR;
    }
    
    /* Create namespace */
    Tcl_Namespace *ns = Tcl_CreateNamespace(interp, "::ifx", NULL, NULL);
    if (ns == NULL) {
        return TCL_ERROR;
    }
    
    /* Register commands */
    Tcl_CreateObjCommand(interp, "::ifx::connect", IfxConnect_Cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::ifx::execute", IfxExecute_Cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::ifx::fetch", IfxFetch_Cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::ifx::close_result", IfxCloseResult_Cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "::ifx::disconnect", IfxDisconnect_Cmd, NULL, NULL);
    
    /* Provide package */
    if (Tcl_PkgProvide(interp, "ifxcli", "1.0") != TCL_OK) {
        return TCL_ERROR;
    }
    
    return TCL_OK;
}

