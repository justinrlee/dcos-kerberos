#!/bin/sh

# KRB5_REALM=MESOS
# KRB5_PASS=password

# haveged

if [ -z ${KRB5_REALM} ]; then
    KRB5_REALM=MESOS
    echo "No KRB5_REALM provided. Using '${KRB5_REALM}'..."
    # exit 1
fi

if [ -z ${KRB5_KDC} ]; then
    KRB5_KDC=localhost
    # krb.marathon.mesos
    echo "No KRB5_KDC provided.  Using '${KRB5_KDC}' ..."
    # exit 1
fi

if [ -z ${KERBEROS_HDFS_FRAMEWORK} ]; then
    KERBEROS_HDFS_FRAMEWORK=hdfs
    echo "No KERBEROS_HDFS_FRAMEWORK provided.  Using '${KERBEROS_HDFS_FRAMEWORK}' ..."
fi

if [ -z ${KERBEROS_HDFS_PRIMARY} ]; then
    KERBEROS_HDFS_PRIMARY=hdfs
    echo "No KERBEROS_HDFS_PRIMARY provided.  Using '${KERBEROS_HDFS_PRIMARY}' ..."
fi

if [ -z ${KERBEROS_HDFS_PRIMARY_HTTP} ]; then
    KERBEROS_HDFS_PRIMARY_HTTP=HTTP
    echo "No KERBEROS_HDFS_PRIMARY_HTTP provided.  Using '${KERBEROS_HDFS_PRIMARY_HTTP}' ..."
fi

if [ -z ${KRB5_ADMINSERVER} ]; then
    echo "No KRB5_ADMINSERVER provided. Using ${KRB5_KDC} in place."
    KRB5_ADMINSERVER=${KRB5_KDC}
    KADMIND_ENABLED=true
fi

if [ ${KADMIND_ENABLED} == true ]; then
    echo "KADMIND_ENABLED is true. Starting kadmind daemon."
    cp -f /etc/supervisord-kadmin.conf /etc/supervisord.conf
else
    echo "KADMIND_ENABLED is not true. Skipping kadmind daemon."
    cp -f /etc/supervisord-kdc.conf /etc/supervisord.conf
fi

if [ ! -f "/var/lib/krb5kdc/principal" ]; then

    echo "No Krb5 Database Found. Creating One with provided information"

    if [ -z ${KRB5_PASS} ]; then
        echo "No Password for kdb provided ... Creating One"
        KRB5_PASS=`< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo;`
        echo "Using Password ${KRB5_PASS}"
    fi

    echo "Creating Krb5 Client Configuration"

cat <<EOT > /etc/krb5.conf
[libdefaults]
 dns_lookup_realm = false
 ticket_lifetime = 24h
 renew_lifetime = 7d
 forwardable = true
 rdns = false
 default_realm = ${KRB5_REALM}
 
 [realms]
 ${KRB5_REALM} = {
    kdc = ${KRB5_KDC}
    admin_server = ${KRB5_ADMINSERVER}
 }
EOT

    echo "Creating KDC Configuration"
cat <<EOT > /var/lib/krb5kdc/kdc.conf
[kdcdefaults]
    kdc_listen = 88
    kdc_tcp_listen = 88
    
[realms]
    ${KRB5_REALM} = {
        kadmin_port = 749
        max_life = 12h 0m 0s
        max_renewable_life = 7d 0h 0m 0s
        master_key_type = aes256-cts
        supported_enctypes = aes256-cts:normal aes128-cts:normal
        default_principal_flags = +preauth
    }
    
[logging]
    kdc = FILE:/var/log/krb5kdc.log
    admin_server = FILE:/var/log/kadmin.log
    default = FILE:/var/log/krb5lib.log
EOT

echo "Creating Default Policy - Admin Access to */admin"
echo "*/admin@${KRB5_REALM} *" > /var/lib/krb5kdc/kadm5.acl
echo "*/service@${KRB5_REALM} aci" >> /var/lib/krb5kdc/kadm5.acl

    echo "Creating Temp pass file"
cat <<EOT > /etc/krb5_pass
${KRB5_PASS}
${KRB5_PASS}
EOT

    echo "Creating krb5util database"
    kdb5_util create -r ${KRB5_REALM} < /etc/krb5_pass
    rm /etc/krb5_pass

    echo "Creating Admin Account"
    kadmin.local -q "addprinc -pw ${KRB5_PASS} admin/admin@${KRB5_REALM}"


    NUM_DATA_NODES=${NUM_DATA_NODES:-3}
    NUM_NAME_NODES=2
    NUM_ZKFC_NODES=2
    NUM_JOURNAL_NODES=3

    mkdir /keytabs

    NODE_LIST=
    for i in $(seq 0 $((${NUM_NAME_NODES}-1))); do NODE_LIST+="name-${i}-node "; done
    for i in $(seq 0 $((${NUM_ZKFC_NODES}-1))); do NODE_LIST+="name-${i}-zkfc "; done
    for i in $(seq 0 $((${NUM_DATA_NODES}-1))); do NODE_LIST+="data-${i}-node "; done
    for i in $(seq 0 $((${NUM_JOURNAL_NODES}-1))); do NODE_LIST+="journal-${i}-node "; done

    for node in ${NODE_LIST}; do
    kadmin.local -q "addprinc -randkey ${KERBEROS_HDFS_PRIMARY}/${node}.${KERBEROS_HDFS_FRAMEWORK}.mesos@${KRB5_REALM}"
    kadmin.local -q "addprinc -randkey ${KERBEROS_HDFS_PRIMARY_HTTP}/${node}.${KERBEROS_HDFS_FRAMEWORK}.mesos@${KRB5_REALM}"
    kadmin.local -q "ktadd -norandkey -k /keytabs/${KERBEROS_HDFS_PRIMARY}.${node}.${KERBEROS_HDFS_FRAMEWORK}.mesos.keytab \
                                            ${KERBEROS_HDFS_PRIMARY}/${node}.${KERBEROS_HDFS_FRAMEWORK}.mesos@${KRB5_REALM} \
                                            ${KERBEROS_HDFS_PRIMARY_HTTP}/${node}.${KERBEROS_HDFS_FRAMEWORK}.mesos@${KRB5_REALM}"
    done

    # ls /srv/

    tar -czvf /srv/keytabs.tar.gz /keytabs/*.keytab
    # cd /srv; tar -czvf /srv/keytabs.tar.gz *.keytab
    # cd -

    # KRB5_REALM
    # KERBEROS_HDFS_FRAMEWORK
    # KERBEROS_HDFS_PRIMARY
    # KERBEROS_HDFS_PRIMARY_HTTP

    # Need to generate keytabs:
    # {{KERBEROS_PRIMARY}}/{{TASK_NAME}}.{{FRAMEWORK_NAME}}.mesos@{{KERBEROS_REALM}}
    # keytabs/{{KERBEROS_PRIMARY}}.{{TASK_NAME}}.{{FRAMEWORK_NAME}}.mesos.keytab

    # Datanode
    # {{KERBEROS_PRIMARY}}/data-{{POD_INSTANCE_INDEX}}-node.{{FRAMEWORK_NAME}}.mesos@{{KERBEROS_REALM}}
    # keytabs/{{KERBEROS_PRIMARY}}.data-{{POD_INSTANCE_INDEX}}-node.{{FRAMEWORK_NAME}}.mesos.keytab

    # Namenode
    # {{KERBEROS_PRIMARY}}/name-{{POD_INSTANCE_INDEX}}-node.{{FRAMEWORK_NAME}}.mesos@{{KERBEROS_REALM}}
    # {{KERBEROS_PRIMARY_HTTP}}/name-{{POD_INSTANCE_INDEX}}-node.{{FRAMEWORK_NAME}}.mesos@{{KERBEROS_REALM}}
    # keytabs/{{KERBEROS_PRIMARY}}.name-{{POD_INSTANCE_INDEX}}-node.{{FRAMEWORK_NAME}}.mesos.keytab

    # zkfc
    # {{KERBEROS_PRIMARY}}/zkfc-{{POD_INSTANCE_INDEX}}-node.{{FRAMEWORK_NAME}}.mesos@{{KERBEROS_REALM}}
    # {{KERBEROS_PRIMARY_HTTP}}/zkfc-{{POD_INSTANCE_INDEX}}-node.{{FRAMEWORK_NAME}}.mesos@{{KERBEROS_REALM}}
    # keytabs/{{KERBEROS_PRIMARY}}.zkfc-{{POD_INSTANCE_INDEX}}-node.{{FRAMEWORK_NAME}}.mesos.keytab

    # journal
    # {{KERBEROS_PRIMARY}}/journal-{{POD_INSTANCE_INDEX}}-node.{{FRAMEWORK_NAME}}.mesos@{{KERBEROS_REALM}}
    # {{KERBEROS_PRIMARY_HTTP}}/journal-{{POD_INSTANCE_INDEX}}-node.{{FRAMEWORK_NAME}}.mesos@{{KERBEROS_REALM}}
    # keytabs/hdfs.journal-{{POD_INSTANCE_INDEX}}-node.{{FRAMEWORK_NAME}}.mesos.keytab
    fi

cp /etc/krb5.conf /srv/

/usr/bin/supervisord -c /etc/supervisord.conf
