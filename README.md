# LogRoller

<img width="128" height="128" alt="icon_128x128" src="https://github.com/dav/LogRoller/blob/main/App/Sources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png?raw=true" />

LogRoller is a macOS app and CLI for collecting and analyzing structured test logs from devices on your local network.

It was initially built to give coding agents a skill that could access event logs from under-develop code running on local test devices. This allows the agents to examine how the code being produced is behaving in manual test runs.

So you can go to your agent and say _"hey those last changes you made don't seem to be working. I just did a test run between the two devices and the transfer didn't succeed."_

And you agent will respond _"Let me run logroller to see what happened...."_

## What It Does

- Runs a local HTTPS ingest server for log events.
- Stores and organizes logs by run and device.
- Provides desktop browsing/filtering for collected logs.
- Exposes a CLI designed for automation and AI-agent workflows.
- Includes a ready-made [SKILL.md](https://github.com/dav/LogRoller/blob/main/skills/logroller-client-integration/SKILL.md) file

<img width="1458" height="575" alt="image" src="https://github.com/user-attachments/assets/ec30eaa7-7c53-455a-9c98-5bd0af6db67e" />

It's not much to look at, but this isn't really for you. It's for your agent.

## Setup

Because of my initial need of collecting data from iPhones running a PWA app in Safari, this uses https/SSL. Currently you'll need to manually set up a root certificate authority on your Mac, and then make it trusted on any clients. It's not too hard, ask your agent about mkcert.

Launching the app starts the webserver on 8443. There's no auth or security.

Once the SKILL.md is made available to your agent, you can ask the agent to add the necessary code to your project.

You and the agent can run `logroller ingest-help` for info on how this works.

You can also test manually using curl:
```
$ curl https://127.0.0.1:8443/healthz

$ curl -sS https://192.168.1.123:8443/ingest \
    -H "Content-Type: application/json" \
    -X POST \
    -d '{
          "ts":"2026-02-19T20:15:01.123Z",
          "level":"info",
          "event":"client.custom_event",
          "run_id":"run_curl_test",
          "device_id":"curl_client_01",
          "seq":1,
          "payload":{"anything":"goes","nested":{"x":1,"flag":true}}
        }'        
```

## License

This repository is licensed under [PolyForm Small Business License 1.0.0](https://polyformproject.org/licenses/small-business/1.0.0).

- Personal use and qualifying small-business use are permitted.
- Larger organizations that do not qualify under the license need a separate commercial license.

See `LICENSE` file in project root for full terms.

## Commercial Licensing

If your organization does not qualify for PolyForm Small Business use and you want to use LogRoller, please open a GitHub issue to request commercial licensing terms.
