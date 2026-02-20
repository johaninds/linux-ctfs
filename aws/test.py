import re
with open('/tmp/ctf_setup.sh', 'r') as f: content = f.read()

# Replace generate_flag_suffix() to restore from EBS or generate+save new one
old_fn = 'generate_flag_suffix() {\n    head -c 4 /dev/urandom | xxd -p\n}'
new_fn = '''generate_flag_suffix() {
    if [ -f /mnt/ctf_ebs/ctf_state/suffix ]; then
        cat /mnt/ctf_ebs/ctf_state/suffix
    else
        local s
        s=$(head -c 4 /dev/urandom | xxd -p)
        echo "$s" > /mnt/ctf_ebs/ctf_state/suffix
        echo "$s"
    fi
}'''
content = content.replace(old_fn, new_fn)

# Replace INSTANCE_ID generation to restore from EBS or generate+save new one
old_id = 'INSTANCE_ID=$(head -c 16 /dev/urandom | xxd -p)'
new_id = 'INSTANCE_ID=$(cat /mnt/ctf_ebs/ctf_state/instance_id 2>/dev/null || (head -c 16 /dev/urandom | xxd -p | tee /mnt/ctf_ebs/ctf_state/instance_id))'
content = content.replace(old_id, new_id)

with open('/tmp/ctf_setup.sh', 'w') as f: f.write(content)
