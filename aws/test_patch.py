import urllib.request

url = 'https://raw.githubusercontent.com/learntocloud/linux-ctfs/main/ctf_setup.sh'
req = urllib.request.Request(url)
with urllib.request.urlopen(req) as response:
    content = response.read().decode('utf-8')

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

old_id = 'INSTANCE_ID=$(head -c 16 /dev/urandom | xxd -p)'
new_id = 'INSTANCE_ID=$(cat /mnt/ctf_ebs/ctf_state/instance_id 2>/dev/null || (head -c 16 /dev/urandom | xxd -p | tee /mnt/ctf_ebs/ctf_state/instance_id))'
content = content.replace(old_id, new_id)

with open('patched_setup.sh', 'w') as f:
    f.write(content)
