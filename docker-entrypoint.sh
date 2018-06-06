#!/bin/sh

# haveged

# Creates /etc/krb5.conf
function krb5_conf() {
    # We start by creating the first part of the file
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
    admin_server = ${KRB5_ADMINSERVER}
EOT

    # Next, we loop through our KDCs and add those
    for kdc in ${KRB5_KDCS}; do
        echo "    kdc = ${kdc}" >> /etc/krb5.conf
    done

    # Finally, close our brackets
    echo "  }" >> /etc/krb5.conf
}

# Creates /var/lib/krb5kdc/kdc.conf
function kdc_conf() {
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
}

function hdfs_keytabs() {
    NODE_LIST=
    for i in $(seq 0 $((${NUM_NAME_NODES}-1))); do NODE_LIST+="name-${i}-node "; done
    for i in $(seq 0 $((${NUM_ZKFC_NODES}-1))); do NODE_LIST+="name-${i}-zkfc "; done
    for i in $(seq 0 $((${NUM_DATA_NODES}-1))); do NODE_LIST+="data-${i}-node "; done
    for i in $(seq 0 $((${NUM_JOURNAL_NODES}-1))); do NODE_LIST+="journal-${i}-node "; done

    for node in ${NODE_LIST}; do
        # Assuming these principals don't exist
        kadmin.local -q "addprinc -randkey ${KERBEROS_HDFS_PRIMARY}/${node}.${KERBEROS_HDFS_FRAMEWORK}.mesos@${KRB5_REALM}"
        kadmin.local -q "addprinc -randkey HTTP/${node}.${KERBEROS_HDFS_FRAMEWORK}.mesos@${KRB5_REALM}"
        kt_file=${KERBEROS_HDFS_PRIMARY}.${node}.${KERBEROS_HDFS_FRAMEWORK}.mesos.keytab
        if [ ! -f /keytabs/${kt_file} ]; then
            kadmin.local -q "ktadd -norandkey -k /keytabs/${KERBEROS_HDFS_PRIMARY}.${node}.${KERBEROS_HDFS_FRAMEWORK}.mesos.keytab \
                             ${KERBEROS_HDFS_PRIMARY}/${node}.${KERBEROS_HDFS_FRAMEWORK}.mesos@${KRB5_REALM} \
                             HTTP/${node}.${KERBEROS_HDFS_FRAMEWORK}.mesos@${KRB5_REALM}"
        fi
    done
}

KRB5_REALM=${KRB5_REALM:-MESOS}
KRB5_ADMINSERVER=${KRB5_ADMINSERVER} # This may end up blank, that's OK
KRB5_PASS=${KRB5_PASS:-$(</dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo)}

# Generate a list of KDCs and support the older KRB5_KDC variable
KRB5_KDCS=${KRB5_KDCS}
KRB5_KDCS=${KRB5_KDCS:-${KRB5_KDC}}
KRB5_KDCS=${KRB5_KDCS:-localhost} # Fallback to localhost

if [ -z ${KRB5_ADMINSERVER} ]; then
    KRB5_ADMINSERVER=$(echo ${KRB5_KDCS} | cut -d' ' -f1) # First KDC, if more
    KADMIND_ENABLED=true
fi

echo "Using Kerberos Realm:         ${KRB5_REALM}"
echo "Using Kerberos Admin Server:  ${KRB5_ADMINSERVER}"
echo "Using Kerberos KDC(s):        ${KRB5_KDCS}"
echo "Using Kerberos password:      ${KRB5_PASS}"

# HDFS section
KERBEROS_HDFS_ENABLED=${KERBEROS_HDFS_ENABLED:-true}
KERBEROS_HDFS_FRAMEWORK=${KERBEROS_HDFS_FRAMEWORK:-hdfs}
# It's principal, but support the legacy variable names
KERBEROS_HDFS_PRINCIPAL=${KERBEROS_HDFS_PRINCIPAL}
KERBEROS_HDFS_PRINCIPAL=${KERBEROS_HDFS_PRINCIPAL:-${KERBEROS_HDFS_PRIMARY}}
KERBEROS_HDFS_PRINCIPAL=${KERBEROS_HDFS_PRINCIPAL:-hdfs}

NUM_NAME_NODES=2
NUM_ZKFC_NODES=2
NUM_JOURNAL_NODES=${NUM_JOURNAL_NODES:-3}
NUM_DATA_NODES=${NUM_DATA_NODES:-3}

if [ ${KERBEROS_HDFS_ENABLED} == true ]; then
    echo
    echo "HDFS Kerberos is enabled"
    echo "Using HDFS Framework:     ${KERBEROS_HDFS_FRAMEWORK}"
    echo "Using Kerberos Principal: ${KERBEROS_HDFS_PRINCIPAL}"
    echo
    echo "Node Counts"
    echo "NameNode(s):    ${NUM_NAME_NODES}"
    echo "ZKFC(s):        ${NUM_ZKFC_NODES}"
    echo "JournalNode(s): ${NUM_JOURNAL_NODES}"
    echo "DataNode(s):    ${NUM_DATA_NODES}"
fi

if [ ! -f "/var/lib/krb5kdc/principal" ]; then
    echo
    echo "Creating /etc/krb5.conf Kerberos client configuration"
    krb5_conf
    echo "Creating /var/lib/krb5kdc/kdc.conf Kerberos KDC configuration"
    kdc_conf
    echo "Creating default Kerberos policy - Admin access to */admin"
    echo "*/admin@${KRB5_REALM} *" > /var/lib/krb5kdc/kadm5.acl
    echo "*/service@${KRB5_REALM} aci" >> /var/lib/krb5kdc/kadm5.acl
    echo "Creating temporary password file"
    echo "${KRB5_PASS} > /etc/krb5_pass
    echo "${KRB5_PASS} >> /etc/krb5_pass
    echo "Creating Kerberos database"
    kdb5_util create -r ${KRB5_REALM} < /etc/krb5_pass
    shred -u /etc/krb5_pass
    echo "Creating Admin (admin/admin) account"
    kadmin.local -q "addprinc -pw ${KRB5_PASS} admin/admin@${KRB5_REALM}"

    mkdir /keytabs
    if [ ${KERBEROS_HDFS_ENABLED} == true ] && [ ${KADMIND_ENABLED} == true ]; then
        # We're a kadmind, so we should create the keytabs, etc
        hdfs_keytabs
    fi

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

if [ ${KADMIND_ENABLED} == true ]; then
    echo "KADMIND_ENABLED is true. Starting kadmind daemon."
    cp -f /etc/supervisord-kadmin.conf /etc/supervisord.conf
else
    echo "KADMIND_ENABLED is not true. Skipping kadmind daemon."
    cp -f /etc/supervisord-kdc.conf /etc/supervisord.conf
fi

/usr/bin/supervisord -c /etc/supervisord.conf
