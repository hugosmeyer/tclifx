# Environment for server (/opt/sup/ifx installation)
export INFORMIXDIR=/opt/sup/ifx
export INFORMIXSQLHOSTS=${INFORMIXDIR}/etc/sqlhosts
export INFORMIXSERVER=eppix310
export ODBCINI=${INFORMIXDIR}/etc/odbc.ini
export ODBCINST=${INFORMIXDIR}/etc/odbcinst.ini
export LD_LIBRARY_PATH=${INFORMIXDIR}/lib:${INFORMIXDIR}/lib/cli:${INFORMIXDIR}/lib/esql:$LD_LIBRARY_PATH

