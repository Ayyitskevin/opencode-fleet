name: OpenCode owner manual build

on:
  workflow_dispatch:
    inputs:
      request:
        description: Bounded implementation request
        required: true
        type: string

permissions:
  contents: write
  pull-requests: write

concurrency:
  group: opencode-build-${{ github.repository }}
  cancel-in-progress: false

jobs:
  build:
    if: >-
      github.actor_id == 133295304 &&
      github.actor == github.repository_owner &&
      github.ref_name == github.event.repository.default_branch
    permissions:
      contents: write
      pull-requests: write
    uses: Ayyitskevin/opencode-fleet/.github/workflows/build.yml@__CENTRAL_SHA__
    with:
      request: ${{ inputs.request }}
