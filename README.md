# 📦 Sea_toggle Homelab Storage Stack

A Linux-first, self-hosted storage system designed for **reliability, simplicity, and low client friction**, with browser-based access as the primary interface.

This README reflects the **current authoritative state** of the system: what is working, what was intentionally abandoned, and which assumptions must hold going forward.

---

## 🧠 Overall Goal

Build a storage stack optimized for:

- Reliable bulk storage (photos, videos, backups, media)
- Browser-based uploads/downloads (multi-client, low friction)
- Avoiding fragile Windows SMB/NFS tuning or registry hacks
- Incremental optimization over time (stability first, speed later)

**Explicit tradeoff:**  
Raw ingest speed from Windows PCs is deprioritized in favor of simplicity, consistency, and UX.

---

## 🏗️ Current Architecture (Authoritative)

### 1️⃣ SeaweedFS — Core Storage Layer

**Role:** Object + volume storage backend

**Components in use:**
- Master(s)
- Volume server(s)
- **S3 Gateway (ENABLED)** ← critical

**Status:** Running and reachable

**Usage model:**
- Acts as an **S3-compatible object store**
- **Not used as a POSIX filesystem**
- **Not mounted on client machines**

---

### 2️⃣ JuiceFS — Filesystem Abstraction Layer

**Role:** POSIX filesystem over object storage

**Metadata backend:**
- Redis 7 (Docker)
- Persistent container: `juicefs-redis`

**Data backend:**
- SeaweedFS S3 Gateway
- Example bucket: `juicefs-media`
- Endpoint: `http://<seaweedfs-host>:8888`

**Important clarifications:**
- ❌ NOT using `--storage file`
- ❌ NOT using `/var/lib/juicefs-data`
- ❌ NOT using SeaweedFS filer directly
- ✅ **Using S3 API only**

⚠️ **If the S3 bucket is deleted, the JuiceFS filesystem is invalid and must be reformatted.**

---

### 3️⃣ JuiceFS Mount

- **Mount point:** `/mnt/juicefs`
- **Host OS:** Debian / Bookworm
- **Runs as:** `root`
- **Purpose:** Provides POSIX semantics for local Linux services only

Clients never access JuiceFS directly.

---

### 4️⃣ CopyParty — Primary Access Method

**Role:** Web UI + upload/download server

**Why CopyParty:**
- No Windows registry changes
- No SMB/NFS client instability
- Works across unmanaged devices
- Browser-native UX

**Known-good invocation:**
```bash
python3 /opt/copyparty/copyparty-sfx.py \
  -p 3923 \
  -a media:changeme \
  -e2dsa \
  --hist /var/lib/copyparty/hist \
  -v :/mnt/juicefs/:rwmda
```

  Key flags:

-e2dsa → thumbnails & media features

rwmda → required for uploads + deletes

Runtime details:

Runs as root

Must be managed by systemd for persistence

5️⃣ Services & Persistence

Docker containers:

juicefs-redis

Grafana

InfluxDB

Telemetry agent

systemd services (implemented or required):

JuiceFS mount

CopyParty

🚫 Explicitly Abandoned / Disabled

The following were intentionally removed and should not be reintroduced:

❌ SMB for client ingest

❌ NFS (removed entirely)

❌ Windows registry / ServicesForNFS tuning

❌ SeaweedFS filer mounts (including OMV)

❌ /var/lib/juicefs-data local backend

Reasons:

Client friction

Permission instability

Poor UX across multiple Windows machines

🧩 Known Issues (Resolved or Understood)
🔹 Upload Failures (HTTP 500)

Causes:

JuiceFS mounted read-only or with wrong permissions

CopyParty lacking write access

UID/GID mismatches

Fix direction:

Ensure JuiceFS mount is writable

Run CopyParty as root

Use rwmda

Avoid chown on object-backed paths (e.g. .trash)

🔹 Thumbnails Missing After Reboot

Causes:

CopyParty not restarting

Missing ffmpeg

Non-persistent cache paths

Resolution:

Install ffmpeg

Run CopyParty as a persistent systemd service

Ensure --hist and volume paths persist

🔹 Redis / S3 Role Confusion

Clarified model:

Redis = metadata ONLY

SeaweedFS S3 = data ONLY

Redis without S3 is useless

Deleting the S3 bucket breaks the filesystem

🧪 Validation Commands

Useful for diagnostics and future debugging:

docker ps
juicefs status redis://127.0.0.1:6379/1
mount | grep juicefs
df -h /mnt/juicefs

🔁 Reset Logic (If Needed)

If the data backend is wiped:

Recreate SeaweedFS S3 bucket

Reformat JuiceFS

Remount JuiceFS

Restart CopyParty

🧭 Future Intent (Not Yet Implemented)

Possible future enhancements (optional):

Higher-speed ingest paths

Multiple S3 gateways

Parallel upload paths

Tiered storage

Monitoring is already in place via InfluxDB + Grafana.

🧠 Mental Model (Key Takeaway)

SeaweedFS stores bytes.
JuiceFS provides filesystem logic.
Redis remembers filenames.
CopyParty is the user interface.
Windows never talks to storage directly.
