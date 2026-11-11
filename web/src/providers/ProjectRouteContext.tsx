// ponytail: Fair Lunch pages have no mutable project alias, so a review never needs a route scope.
export type ProjectReviewScope = { identity: string; verify: () => Promise<boolean> }

export function useProjectReviewScope(): ProjectReviewScope | null {
  return null
}
