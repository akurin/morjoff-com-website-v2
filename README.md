# morjoff.com

Personal website, built with [Hugo](https://gohugo.io/) and the
[hugo-coder](https://github.com/luizdepra/hugo-coder) theme (vendored in `hugo/themes/`).

## Writing a post

```sh
cd hugo
hugo new content posts/my-post.md   # starts as a draft; fill in title and description
hugo server -D                      # preview at http://localhost:1313, drafts included
```

Set `draft = false` when the post is ready. Drafts are never published.

## Building

The site is built inside the Docker image with a pinned Hugo version (see `Dockerfile`), so
`hugo/public/` isn't committed. To check the production build locally:

```sh
docker build -t morjoff-com .
docker run --rm -p 8080:8080 morjoff-com    # http://localhost:8080
```

## Deploying

Pushing to `master` builds the image, pushes it to `ghcr.io/akurin/morjoff-com-website-v2` and
deploys it to the k3s cluster with the Helm chart in `helm/` (see
`.github/workflows/ci.yml`). Pull requests only build the image.

The deploy job needs these repository secrets: `KUBECONFIG`, `CI_DEPLOY_SSH_KEY`, `K3S_HOST`
and `K3S_KNOWN_HOSTS` (the host's `known_hosts` line, used to verify the SSH tunnel).
