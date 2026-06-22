# External EBS Volume for Babelfish Data

This project is configured to keep Babelfish/PostgreSQL data on an external EBS volume mounted at:

```text
/mnt/babelfish-data
```

The Docker Compose data path should point there via `.env`:

```env
BABELFISH_DATA_PATH=/mnt/babelfish-data
```

## Current example layout

On the EC2 instance, `lsblk` showed:

```text
nvme0n1   30G   root/OS disk
nvme1n1  100G   external EBS data disk
```

The external EBS device was formatted as ext4 and mounted at `/mnt/babelfish-data`.

Current filesystem UUID used in `/etc/fstab`:

```text
b9843636-f129-460c-bcd2-cb2fe999b193
```

`/etc/fstab` entry:

```fstab
UUID=b9843636-f129-460c-bcd2-cb2fe999b193 /mnt/babelfish-data ext4 defaults,nofail 0 2
```

After changing `/etc/fstab`, reload systemd:

```bash
sudo systemctl daemon-reload
```

## Check the mounted volume

```bash
lsblk
sudo lsblk -f /dev/nvme1n1
df -h /mnt/babelfish-data
```

Expected result should show `/dev/nvme1n1` mounted at `/mnt/babelfish-data`.

## Initial setup commands for a blank EBS volume

Only run `mkfs.ext4` on a blank/new EBS volume. It destroys existing data.

Check first:

```bash
sudo lsblk -f /dev/nvme1n1
sudo file -s /dev/nvme1n1
```

If it reports `data`, format and mount:

```bash
sudo mkfs.ext4 /dev/nvme1n1
sudo mkdir -p /mnt/babelfish-data
sudo mount /dev/nvme1n1 /mnt/babelfish-data
sudo chown -R ubuntu:ubuntu /mnt/babelfish-data
```

Get the UUID:

```bash
sudo blkid /dev/nvme1n1
```

Add to `/etc/fstab`, replacing `YOUR_UUID_HERE`:

```bash
echo 'UUID=YOUR_UUID_HERE /mnt/babelfish-data ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
```

Test the mount:

```bash
sudo umount /mnt/babelfish-data
sudo mount -a
df -h /mnt/babelfish-data
```

## Point Docker Compose to the EBS volume

From the repo directory:

```bash
cd ~/docker-babelfishpg

grep -q '^BABELFISH_DATA_PATH=' .env \
  && sed -i 's|^BABELFISH_DATA_PATH=.*|BABELFISH_DATA_PATH=/mnt/babelfish-data|' .env \
  || echo 'BABELFISH_DATA_PATH=/mnt/babelfish-data' >> .env

grep '^BABELFISH_DATA_PATH=' .env
```

Start Babelfish:

```bash
docker compose up -d
docker compose ps
```

## Extending the external EBS volume

If the external EBS volume is expanded in AWS, no Docker Compose or `.env` change is needed as long as the mount path remains the same:

```env
BABELFISH_DATA_PATH=/mnt/babelfish-data
```

After increasing the EBS size in AWS, verify the OS sees the new size:

```bash
lsblk
```

For this setup, the ext4 filesystem is directly on the disk `/dev/nvme1n1`, not on a partition. Grow the filesystem with:

```bash
sudo resize2fs /dev/nvme1n1
```

Verify the new available size:

```bash
df -h /mnt/babelfish-data
```

If the volume was partitioned in a future setup, for example `/dev/nvme1n1p1`, use `growpart` first and then resize the partition filesystem. That is not needed for the current direct-on-disk setup.
