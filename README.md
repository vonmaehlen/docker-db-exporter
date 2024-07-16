Docker Database Exporter
========================

```
$ ./docker-db-dump.sh --help

Usage: docker-db-dump.sh [flags]

Create consistent backups for all databases in locally running containers.

  -c, --container <name>    Add container to the list of backup-tasks.
  -s, --skip <name>         Do not warn that the container is not backed up.
  -d, --backup-dir <path>   Directory to store backups. Default: ./_db_backups
  -n, --keep <count>        Number of backups to keep per container. Default: 4
      --ping <url>          Send a heartbeat after the command ran.
      --ping-error <url>    Send a heartbeat if the command (partially) failed.
      --ping-success <url>  Send a heartbeat if the command succeeded.
  -h, --help                Print this help message and exit.
  -v, --verbose             Increase logging.
```

Goal of this project is to create a consistent backup of databases running in
Docker containers while they are still running. This is usefull for having
production setups utilizing container technology that should have a relatively
high uptime.
