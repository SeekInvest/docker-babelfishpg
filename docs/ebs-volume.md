# External EBS Volume for Babelfish Data

This project is configured to keep Babelfish/PostgreSQL data on an external EBS volume mounted at:

```text
/mnt/babelfish-data
```

Do **not** point PostgreSQL directly at the mount root because an ext4 filesystem contains a `lost+found` directory there, and `initdb` requires an empty data directory.

Use a subdirectory for the actual PostgreSQL/Babelfish data:

```text
/mnt/babelfish-data/pgdata
```

The Docker Compose data path should point there via `.env`:

```env
BABELFISH_DATA_PATH=/mnt/babelfish-data/pgdata
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
sudo mkdir -p /mnt/babelfish-data/pgdata
# The container runs PostgreSQL as the container's postgres user.
# Check the actual UID/GID from the image before starting.
docker compose run --rm --no-deps --entrypoint sh babelfish -c 'id -u; id -g'

# If Docker user namespace remapping is not enabled, make the host
# directory owned by that same UID/GID.
# If user namespace remapping is enabled, use the mapped host UID/GID
# from the troubleshooting section below instead.
sudo chown -R 1001:1001 /mnt/babelfish-data/pgdata
sudo chmod 700 /mnt/babelfish-data/pgdata
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
  && sed -i 's|^BABELFISH_DATA_PATH=.*|BABELFISH_DATA_PATH=/mnt/babelfish-data/pgdata|' .env \
  || echo 'BABELFISH_DATA_PATH=/mnt/babelfish-data/pgdata' >> .env

grep '^BABELFISH_DATA_PATH=' .env
```

Start Babelfish:

```bash
docker compose up -d --no-build babelfish
docker compose ps
```

If `initdb` fails with `could not change permissions of directory` or `Permission denied`, first confirm Compose is using the subdirectory:

```bash
grep '^BABELFISH_DATA_PATH=' .env
docker compose config | grep -B3 -A5 '/var/lib/babelfish/data'
```

Then check the UID/GID and UID/GID mapping used by the image:

```bash
docker compose run --rm --no-deps --entrypoint sh babelfish -c '
  echo "id:"
  id
  echo "uid_map:"
  cat /proc/self/uid_map
  echo "gid_map:"
  cat /proc/self/gid_map
'
```

### Fix used on this EC2 server

On this server, the container reported:

```text
uid=1001(postgres) gid=1001(postgres)
uid_map:
         0       1000          1
         1     100000      65536
gid_map:
         0       1000          1
         1     100000      65536
```

That means Docker user namespace remapping is enabled. Container UID/GID `1001:1001` maps to host UID/GID `101000:101000`:

```text
host id = 100000 + (container id - 1)
host id = 100000 + (1001 - 1) = 101000
```

If the host directory is owned by `1001:1001`, it appears inside the container as `nobody:nogroup` / `65534:65534` and PostgreSQL cannot write to it.

The working fix was:

```bash
cd ~/docker-babelfishpg

docker compose down

sudo rm -rf /mnt/babelfish-data/pgdata
sudo mkdir -p /mnt/babelfish-data/pgdata
sudo chown 101000:101000 /mnt/babelfish-data/pgdata
sudo chmod 700 /mnt/babelfish-data/pgdata

ls -ldn /mnt/babelfish-data/pgdata
```

Expected host ownership:

```text
drwx------ ... 101000 101000 ... /mnt/babelfish-data/pgdata
```

Verify from inside the container:

```bash
docker compose run --rm --no-deps --entrypoint sh babelfish -c '
  id
  ls -ldn /var/lib/babelfish/data
  touch /var/lib/babelfish/data/.perm-test
  rm /var/lib/babelfish/data/.perm-test
  echo writable
'
```

Expected container ownership/result:

```text
drwx------ ... 1001 1001 ... /var/lib/babelfish/data
writable
```

Then start:

```bash
docker compose up -d --no-build babelfish
docker compose logs -f babelfish
```

A successful startup includes:

```text
Success. You can now start the database server
...
database system is ready to accept connections
```

### If Docker is installed as Snap

If permissions still fail even with correct ownership, check whether Docker was installed as a Snap package. Snap Docker can block bind mounts under `/mnt` unless removable media access is connected:

```bash
snap list docker || true
sudo snap connect docker:removable-media || true
sudo snap restart docker || true
```

Then retry `docker compose up -d --no-build babelfish`.

## Extending the external EBS volume

If the external EBS volume is expanded in AWS, no Docker Compose or `.env` change is needed as long as the data path remains the same:

```env
BABELFISH_DATA_PATH=/mnt/babelfish-data/pgdata
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
