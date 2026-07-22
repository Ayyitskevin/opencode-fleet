name: OpenCode owner review

on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]

permissions:
  contents: read
  issues: write
  pull-requests: write

concurrency:
  group: opencode-review-${{ github.repository }}-${{ github.event.comment.id }}
  cancel-in-progress: true

jobs:
  review:
    if: >-
      github.actor_id == 133295304 &&
      github.event.comment.user.id == 133295304 &&
      github.event.comment.author_association == 'OWNER' &&
      (
        github.event.comment.body == '/oc review' ||
        startsWith(github.event.comment.body, '/oc review: ') ||
        github.event.comment.body == '/oc plan' ||
        startsWith(github.event.comment.body, '/oc plan: ')
      )
    uses: Ayyitskevin/opencode-fleet/.github/workflows/review.yml@__CENTRAL_SHA__
