# minimon

Bash script to monitor HTTP and generic TCP services.

- Only requires `curl` and `ping` (Linux and Windows is supported)
- Supports ICMP, HTTP(S) and generic TCP connections
- Define a alias name behind the URL
- Send a [ASCII Bell](https://en.wikipedia.org/wiki/Bell_character) on state changes
- Works on Git Bash (MinGW) on Windows

## Usage

```sh
./minimon.sh --interval 60 \
    --tcp "localhost:22" \
    --tcp "files:445;fileserver" \
    --http "https://google.com;google" \
    --http "https://example.com" \
    --icmp "8.8.8.8;google"
```

```txt
[2020-11-04T23:44:12+01:00] http_google - https://google.com - OK (0) - HTTP 200
[2020-11-04T23:44:13+01:00] http - https://example.com - OK (0) - HTTP 200
[2020-11-04T23:44:14+01:00] tcp - localhost:22 - NOK (2) - Connect failed
[2020-11-04T23:44:14+01:00] icmp_google - 8.8.8.8 - OK (0) - Ping succeeded (0% loss)
[2020-11-04T23:44:15+01:00] tcp_fileserver - files:445 - OK (0) - Connect successful
[2020-11-04T23:45:17+01:00] tcp - localhost:22 - OK (0) - Connect successful - changed after 63s
```
