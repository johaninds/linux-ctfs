<<EOT
    #!/bin/bash
    EBS_MOUNT="/mnt/ctf_ebs"
    EBS_DEVICE=""

    # Wait up to 60s for EBS to be attached
    for i in $(seq 1 30); do
      if [ -b "/dev/nvme1n1" ]; then
        EBS_DEVICE="/dev/nvme1n1"
        break
      elif [ -b "/dev/xvdf" ]; then
        EBS_DEVICE="/dev/xvdf"
        break
      fi
      sleep 2
    done

    # Mount EBS and set up persistent state directories
    if [ -n "$EBS_DEVICE" ]; then
      if ! blkid "$EBS_DEVICE" > /dev/null 2>&1; then
        mkfs.ext4 -F "$EBS_DEVICE"
      fi
      mkdir -p "$EBS_MOUNT"
      mount "$EBS_DEVICE" "$EBS_MOUNT"
      mkdir -p "$EBS_MOUNT/ctf_state" "$EBS_MOUNT/ctf_progress"
      # Auto-mount on reboot
      echo "$EBS_DEVICE $EBS_MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
    else
      # Fallback so setup doesn't crash if volume fails to attach
      mkdir -p "$EBS_MOUNT/ctf_state" "$EBS_MOUNT/ctf_progress"
    fi

    # Download ctf_setup.sh
    curl -fsSL https://raw.githubusercontent.com/learntocloud/linux-ctfs/main/ctf_setup.sh -o /tmp/ctf_setup.sh

    # Patch ctf_setup.sh to persist/restore INSTANCE_SUFFIX and INSTANCE_ID from EBS
    # This ensures the same flags are generated on every redeploy
    python3 << 'PYEOF'
import re

with open('/tmp/ctf_setup.sh', 'r') as f:
    content = f.read()

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

with open('/tmp/ctf_setup.sh', 'w') as f:
    f.write(content)
PYEOF

    bash /tmp/ctf_setup.sh

    # Symlink /var/ctf to EBS so all progress writes go directly to EBS
    if mountpoint -q "$EBS_MOUNT"; then
      cp -rp /var/ctf/. "$EBS_MOUNT/ctf_progress/" 2>/dev/null || true
      rm -rf /var/ctf
      ln -sf "$EBS_MOUNT/ctf_progress" /var/ctf
    fi

EOT
