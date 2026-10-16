# The demo host

The disposable Linux machine App Review pairs with: Herdr, sshd and `bleat` on
Fly, at https://bleat-demo.fly.dev. What is on it, why it is safe to hand out,
and why no AI agent runs there: [`docs/demo-host.md`](../docs/demo-host.md).

```sh
# once
fly apps create bleat-demo --org personal
fly volumes create bleat_demo_data --app bleat-demo --region sjc --size 1
fly ips allocate-v4 --app bleat-demo        # dedicated, $2/month: SSH is raw TCP
fly ips allocate-v6 --app bleat-demo
fly secrets set DEMO_PASSWORD=… --app bleat-demo

# each change
cd Demo && fly deploy --app bleat-demo --remote-only --ha=false

# a look inside (fly ssh console cannot connect: outbound is blocked)
fly machine exec <machine-id> --app bleat-demo "<command>"
```

The image installs the published `bleat` (`BLEAT_VERSION` in the Dockerfile)
and the latest herdr.
