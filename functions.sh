
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_rsa"
SSH="ssh ${SSH_OPTS}"
SCP="scp ${SSH_OPTS}"

wait_for_machine()
{
    while true;
    do
        ${SSH} $1 /usr/bin/true 2>/dev/null
        if test $? -eq 0; then
            break
        fi
        sleep 10
    done
}
