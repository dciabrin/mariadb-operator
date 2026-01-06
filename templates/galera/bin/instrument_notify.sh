#!/bin/bash

touch /tmp/logz
echo "CALLED: $*" >> /tmp/logz
ls /var/lib/mysql >> /tmp/logz
[ ! -f /var/lib/mysql/keep ]
echo OUT: $? >> /tmp/logz
if [ ! -f /var/lib/mysql/keep ]; then
    cp /tmp/logz /var/lib/mysql/keep
    sync
    killall -9 /usr/libexec/mysqld
fi
if echo "$*" | grep -i disconnect; then
    rm /var/lib/mysql/keep
fi

exec /usr/local/bin/mysql_wsrep_notify.sh $*
