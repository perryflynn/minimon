# minimon

Bash script to monitor HTTP and generic TCP services.

- Only requires `curl` and `ping` (Linux and Windows is supported)
- Supports ICMP, HTTP(S) and generic TCP connections
- Enforce IPv4 or IPv6 for single checks
- Define a alias name behind the URL
- Send a [ASCII Bell](https://en.wikipedia.org/wiki/Bell_character) on state changes
- Works on Git Bash (MinGW) on Windows
- Limit the number of checks to use the script as healthcheck in CI pipelines
- Use simple shell scripts as check plugins
- Executes checks in parallel (controlled by `--parallel` option)
- Load settings from a json file (see `--config`, requires `jq`)

## Download

```sh
curl -L https://github.com/perryflynn/minimon/raw/master/minimon.sh > minimon.sh && chmod a+x minimon.sh
```

## Usage

```txt
minimon by Christian Blechert
https://github.com/perryflynn/minimon

Usage: ./minimon.sh [--interval 30] [--tcp "example.com:4242[;aliasname]"]

--interval n       Delay between two checks
--tcp host:port    Check a generic TCP port
--tcp4 host:port   Check a generic TCP port, force IPv4
--tcp6 host:port   Check a generic TCP port, force IPv6
--http url         Check a HTTP(S) URL
--http4 url        Check a HTTP(S) URL, force IPv4
--http6 url        Check a HTTP(S) URL, force IPv6
--icmp host        Ping a Hostname/IP
--icmp4 host       Ping a Hostname/IP, force IPv4
--icmp6 host       Ping a Hostname/IP, force IPv6
--script script    Path to a script to use as a check

Append a alias name to a check separated by a semicolon:
--icmp "8.8.8.8;google"

Load settings from json files:
--config some-config.json

Schema for editors like VSCode:
https://files.serverless.industries/schemas/minimon.json

A script must output one line of text
and must set a exit code like so:
0=OK; 1=WARN; 2=NOK; 3=UNKNOWN

--max-checks n     Only test n times
exit 0 = all ok; exit 1 = partially ok; exit 2 = all failed

--no-redirect       Do not follow HTTP redirects
--invalid-tls       Ignore invalid TLS certificates
--timeout           curl operation timeout
--connect-timeout   curl connect timeout
--parallel 10       number of checks execute in parallel
--no-timestamps     disable timestamps
--short-timestamps  only show time, not the date
--time-spacer 30    add a spacer line if n seconds was no state change

-v, --verbose      Enable verbose mode
-w, --warnings     Show warning output
-e, --errors       Show error output
-h, --help         Print this help
-V, --version      Print the version
```

```sh
./minimon.sh --interval 60 \
    --tcp "localhost:22" \
    --tcp "files:445;fileserver" \
    --http "https://google.com;google" \
    --http "https://example.com" \
    --script "./myscript arg1;scriptname" \
    --icmp "8.8.8.8;google"
```

Output:

```txt
[2020-11-04T23:44:12+01:00] http_google - https://google.com - OK (0) - HTTP 200
[2020-11-04T23:44:13+01:00] http - https://example.com - OK (0) - HTTP 200
[2020-11-04T23:44:14+01:00] tcp - localhost:22 - NOK (2) - Connect failed
[2020-11-04T23:44:14+01:00] icmp_google - 8.8.8.8 - OK (0) - Ping succeeded (0% loss)
[2020-11-04T23:44:15+01:00] tcp_fileserver - files:445 - OK (0) - Connect successful
[2020-11-04T23:45:17+01:00] tcp - localhost:22 - OK (0) - Connect successful - changed after 63s
```

Verbose output:

```txt
[DEBUG] check_http https://google.com
0,179706    200    2    0
[2020-11-07T12:13:06+01:00] http_google - https://google.com - OK (0) - HTTP 200
[DEBUG] check_http https://example.com
0,436060    200    1    0
[2020-11-07T12:13:07+01:00] http - https://example.com - OK (0) - HTTP 200
[DEBUG] check_tcp localhost:22
* Rebuilt URL to: telnet://localhost:22/
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
  0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0*   Trying 127.0.0.1...
* TCP_NODELAY set
* Connected to localhost (127.0.0.1) port 22 (#0)
[2020-11-07T12:13:08+01:00] tcp - localhost:22 - OK (0) - Connect successful
[DEBUG] check_tcp files:445
* Rebuilt URL to: telnet://files:445/
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
  0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0*   Trying 192.168.99.104...
* TCP_NODELAY set
* Connected to files (192.168.99.104) port 445 (#0)
[2020-11-07T12:13:09+01:00] tcp_fileserver - files:445 - OK (0) - Connect successful
[DEBUG] check_icmp 8.8.8.8
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=118 time=11.5 ms
64 bytes from 8.8.8.8: icmp_seq=2 ttl=118 time=11.7 ms
64 bytes from 8.8.8.8: icmp_seq=3 ttl=118 time=12.9 ms

--- 8.8.8.8 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2003ms
rtt min/avg/max/mdev = 11.585/12.084/12.968/0.633 ms
```
