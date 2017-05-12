#!/bin/bash

# Update APEX

echo "This script will uninstall APEX 4.0.2 from Oracle Database 11g Express Edition."
echo "Before continuing, backup all APEX applications."
read -p "Continue (y/n)? " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then


# set variables
APEX_VERSION="5.1.1"
APEX_DOWNLOAD_URL=$1
ORACLE_BASE="/u01/app/oracle"

# uninstall APEX 4
cd $ORACLE_HOME/apex
su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
  @apxremov.sql
  exit;
EOF"
# "mv" doesn't work cause image directory is persistent (volume)
cp -rp $ORACLE_HOME/apex $ORACLE_HOME/apex_4.0.2
find -maxdepth 1 -type d -not -name "images" -not -name "." -exec rm -rf {} \;
find -type f -exec rm -r {} \;

# download and extract APEX 5
curl -f#L $APEX_DOWNLOAD_URL | bsdtar -xf- -C /tmp
# "mv" doesn't work cause image directory is persistent (volume)
cp -r /tmp/apex $ORACLE_HOME
rm -rf /tmp/apex
chown -R oracle:dba $ORACLE_HOME/apex
chmod 755 $ORACLE_HOME/apex
find $ORACLE_HOME/apex -type d -exec chmod 755 {} \;

# create a new tablespace to act as the default tablespace for APEX
su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
  create tablespace APEX datafile '$ORACLE_BASE/oradata/$ORACLE_SID/apex.dbf' size 10m autoextend on next 1m maxsize unlimited;
  exit;
EOF"

cd $ORACLE_HOME/apex
su -s /bin/bash oracle -c "sqlplus -S / as sysdba @apexins.sql APEX APEX TEMP /i/"

# now scan for ORA errors or compilation errors
echo
echo "If there are ORA errors or compilation errors you will find them below!"
echo

grep ORA- *.log
grep PLS- *.log

# need to remove the "HIDE" from the accept statement or else the << EOF1 doesn't work
sed -i 's/password \[\] " HIDE/password \[\] "/g' $ORACLE_HOME/apex/apxchpwd.sql

# set password and disable XDB HTTP and FTP listener
APEX_ADMIN_PWD=${APEX_ADMIN_PWD:-"`cat /dev/urandom | tr -dc 'a-zA-Z0-9!#$%&()*+,-/:;?_' | fold -w 10 | grep -i '[!#$%&()*+,-/:;?_]' | grep '[0-9]' | grep '[a-z]' | grep '[A-Z]' | head -n 1`"}
APEX_ADMIN_PWD_FILE=$ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/.apex_admin.passwd
echo -n $APEX_ADMIN_PWD > $APEX_ADMIN_PWD_FILE
chmod 600 $APEX_ADMIN_PWD_FILE
chown root:root $APEX_ADMIN_PWD_FILE

# make sure no indents
su -s /bin/bash oracle -c "sqlplus -S / as sysdba @apxconf.sql <<EOF1
ADMIN
ADMIN
$APEX_ADMIN_PWD
0
EOF1"

# anonymous user is not needed when we don't use XDB
su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
  exec dbms_xdb.setftpport(0);
  alter user ANONYMOUS account lock;
  exit;
EOF"

# configure RESTful Services
APEX_LISTENER_PWD=${APEX_LISTENER_PWD:-"`tr -dc A-Za-z0-9 < /dev/urandom | head -c8`"}
APEX_LISTENER_PWD_FILE=$ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/.apex_listener.passwd
echo -n $APEX_LISTENER_PWD > $APEX_LISTENER_PWD_FILE
chmod 600 $APEX_LISTENER_PWD_FILE
chown root:root $APEX_LISTENER_PWD_FILE

APEX_REST_PUBLIC_USER_PWD=${APEX_REST_PUBLIC_USER_PWD:-"`tr -dc A-Za-z0-9 < /dev/urandom | head -c8`"}
APEX_REST_PUBLIC_USER_PWD_FILE=$ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/.apex_rest_public_user.passwd
echo -n $APEX_REST_PUBLIC_USER_PWD > $APEX_REST_PUBLIC_USER_PWD_FILE
chmod 600 $APEX_REST_PUBLIC_USER_PWD_FILE
chown root:root $APEX_REST_PUBLIC_USER_PWD_FILE

su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
  @apex_rest_config_core.sql $APEX_LISTENER_PWD $APEX_REST_PUBLIC_USER_PWD
  exit;
EOF"

# now scan for ORA errors or compilation errors
echo
echo "If there are ORA errors or compilation errors you will find them below!"
echo

grep ORA- *.log
grep PLS- *.log

# Oracle’s advice for the APEX_PUBLIC_USER is to set the PASSWORD_LIFE_TIME to UNLIMITED.
# To do this we have to create a new profile.
su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
  create profile APEX_PUBLIC limit
    failed_login_attempts 10
    password_life_time unlimited
    password_reuse_time unlimited
    password_reuse_max unlimited
    password_lock_time 1
    composite_limit unlimited
    sessions_per_user unlimited
    cpu_per_session unlimited
    cpu_per_call unlimited
    logical_reads_per_session unlimited
    logical_reads_per_call unlimited
    idle_time unlimited
    connect_time unlimited
    private_sga unlimited;
  exit;
EOF"

# next, we assign this profile to APEX_LISTENER, APEX_REST_PUBLIC_USER
su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
  alter user APEX_LISTENER profile APEX_PUBLIC;
  alter user APEX_REST_PUBLIC_USER profile APEX_PUBLIC;
  exit;
EOF"


fi;