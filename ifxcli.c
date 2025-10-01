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

/* Read DSN configuration from odbc.ini */
static int read_odbc_ini(const char *dsn, char *user, char *password, int bufsize) {
    FILE *fp;
    char *ini_paths[] = {
        "/etc/odbc.ini",
        NULL  /* Will be replaced with $HOME/.odbc.ini */
    };
    char home_ini[512];
    char line[1024];
    int in_section = 0;
    int found = 0;
    
    /* Setup home path */
    const char *home = getenv("HOME");
    if (home) {
        snprintf(home_ini, sizeof(home_ini), "%s/.odbc.ini", home);
        ini_paths[1] = home_ini;
    }
    
    user[0] = '\0';
    password[0] = '\0';
    
    /* Try each ini file */
    for (int i = 0; ini_paths[i] != NULL; i++) {
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
                    
                    /* Trim key */
                    char *k = key + strlen(key) - 1;
                    while (k >= key && (*k == ' ' || *k == '\t')) *k-- = '\0';
                    
                    /* Copy value and trim */
                    strncpy(value, eq+1, sizeof(value)-1);
                    value[sizeof(value)-1] = '\0';
                    char *v = value;
                    while (*v == ' ' || *v == '\t') v++;
                    char *vend = v + strlen(v) - 1;
                    while (vend >= v && (*vend == ' ' || *vend == '\t' || *vend == '\n')) *vend-- = '\0';
                    
                    /* Check for uid/logonid */
                    if (strcasecmp(key, "uid") == 0 || strcasecmp(key, "logonid") == 0) {
                        strncpy(user, v, bufsize-1);
                        user[bufsize-1] = '\0';
                        found = 1;
                    }
                    /* Check for pwd/password */
                    else if (strcasecmp(key, "pwd") == 0 || strcasecmp(key, "password") == 0) {
                        strncpy(password, v, bufsize-1);
                        password[bufsize-1] = '\0';
                        found = 1;
                    }
                }
            }
        }
        
        fclose(fp);
        if (found) return 1;
    }
    
    return 0;
}

/* ifx::connect dsn ?user? ?password? */
static int IfxConnect_Cmd(ClientData clientData, Tcl_Interp *interp, 
                          int objc, Tcl_Obj *CONST objv[]) {
    IfxConnection *conn;
    SQLRETURN ret;
    char *dsn, *user = "", *password = "";
    char user_buf[256], pwd_buf[256];
    char conn_name[64];
    static int conn_counter = 0;
    
    if (objc < 2 || objc > 4) {
        Tcl_WrongNumArgs(interp, 1, objv, "dsn ?user? ?password?");
        return TCL_ERROR;
    }
    
    dsn = Tcl_GetString(objv[1]);
    
    /* Read from odbc.ini if credentials not provided */
    if (objc < 3) {
        if (read_odbc_ini(dsn, user_buf, pwd_buf, sizeof(user_buf))) {
            user = user_buf;
            password = pwd_buf;
        }
    } else {
        user = Tcl_GetString(objv[2]);
        if (objc >= 4) {
            password = Tcl_GetString(objv[3]);
        }
    }
    
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
    
    /* Connect to database */
    ret = SQLConnect(conn->hdbc,
                     (SQLCHAR *)dsn, SQL_NTS,
                     (SQLCHAR *)user, SQL_NTS,
                     (SQLCHAR *)password, SQL_NTS);
    
    if (ret != SQL_SUCCESS && ret != SQL_SUCCESS_WITH_INFO) {
        SQLFreeHandle(SQL_HANDLE_DBC, conn->hdbc);
        SQLFreeHandle(SQL_HANDLE_ENV, conn->henv);
        ckfree((char *)conn);
        Tcl_SetResult(interp, "Failed to connect to database", TCL_STATIC);
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
    if (ret != SQL_SUCCESS && ret != SQL_SUCCESS_WITH_INFO) {
        SQLFreeHandle(SQL_HANDLE_STMT, hstmt);
        Tcl_SetResult(interp, "Failed to execute SQL", TCL_STATIC);
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

