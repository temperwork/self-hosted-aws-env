# Browser access

The studio's page shows your files: images, listings and outputs. To do that, the browser downloads them **directly from your bucket**, using short-lived links that the studio signs. The studio never proxies your data. `browser_access` decides from where those links work.

## `vpce`: through your S3 VPC endpoints (default, recommended)

Links work only for requests that arrive through one of the endpoints you list in `vpc_endpoint_id` / `vpc_endpoint_ids`.

- **Browsers inside a VPC** (for example, a virtual desktop) use the VPC's S3 **gateway** endpoint. Nothing else is needed.
- **Browsers on laptops** need a way into the VPC. That usually means a VPN to the VPC, plus an S3 **interface** endpoint with private DNS, so that `<bucket>.s3.<region>.amazonaws.com` resolves to the endpoint while someone is on the VPN.

`modules/network` creates both kinds of endpoint, and an AWS Client VPN with `vpn = true`. See [network.md](network.md).

If your browsers can't use private DNS, put the interface endpoint's own DNS name in the Add environment form's **browser endpoint** field (`terraform output browser_endpoint` in `examples/complete`). The studio then signs links for that host.

## `ip`: from your public IP ranges

Links work only from the addresses in `browser_cidrs`, for example your office's egress range or your corporate VPN's exit addresses. No VPC endpoint is needed.

```hcl
browser_access = "ip"
browser_cidrs  = ["203.0.113.0/24", "198.51.100.7/32"]
```

Requests that arrive through a VPC endpoint have no source IP and are denied in this mode. If your workers also read data through a gateway endpoint, that's fine: the restriction applies only to the studio's role, not to your workers' role.

## `open`: anywhere

The module adds no bucket policy. Links work from anywhere, and the studio's role could also read your data itself. Use this only for test data.

## CORS

Whatever the mode, the bucket needs a CORS rule that allows `GET` from the studio's origin. The module sets it from `studio_origins` (default `["https://temperwork.com"]`).

## Other ways in

Any private host that serves the bucket works too, for example a private CloudFront distribution or an internal proxy. Put its base URL in the form's **files base URL** field. File links then go to `<base>/<key>` and aren't signed. Listings still use signed S3 links.

## Checking it

From a machine inside your network, open a dataset in the studio and confirm the images load. From a machine outside your network, the same page should show the files as unavailable. Your browser's dev tools will show `403 AccessDenied` from S3.
