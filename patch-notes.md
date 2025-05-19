
# Table of Contents

1.  [Scope](#org39b3746)
    1.  [Current State](#org547d550)
    2.  [Proposed Solution](#orgb8c7698)
        1.  [Histogram bounds](#org63620ef)
        2.  [Histogram freqs](#org8edf572)
2.  [Details](#orga6d053d)
    1.  [Non transactional nature of pd\_prune\_xid](#org65c9853)
    2.  [Moving from per-backend stats to shared stats](#org1d8f9b9)
    3.  [Histogram balance](#orgbfd44a2)
    4.  [Histogram merging](#org62985bc)
    5.  [Final Solution](#orgdcc9d1d)



<a id="org39b3746"></a>

# Scope

We want to estimate how many pages will be affected by a vacuum operation.


<a id="org547d550"></a>

## Current State

Vacuum can remove dead tuples whose xid (xmax) is smaller than **oldest\_nonremovable**, which keeps moving forward over time.

Every page has a header field **pd\_prune\_xid** that contains the oldest xid among the dead tuples in the page.


<a id="orgb8c7698"></a>

## Proposed Solution

We initialize and maintain a histogram of pd\_prune\_xid's whose bounds evolve dynamically in pace with **oldest\_nonremovable**. There is one histogram per relation and it lives in pgstats catalog.


<a id="org63620ef"></a>

### Histogram bounds

The highest bin is the only one whose upper bound changes at the moment of increasing/decreasing the counter. If the pd\_prune\_xid is higher then the highest upper bound, we update it. On the other extreme, we have an implicit open lower bound since we don't track the lower bounds.

All intermediate bounds are modified at **histogram balance** time. At this moment, two consecutive bins can be merged, shifting remaining bins to the left, creating a fresh highest bin. See futher for the exact conditions on which the merge happens.


<a id="org8edf572"></a>

### Histogram freqs

Whenever a pd\_prune\_xid is modified, keep track of old and new values, reporting to pgstats. Then, increase the bin for the new value and decrease the bin for the old value.


<a id="orga6d053d"></a>

# Details


<a id="org65c9853"></a>

## Non transactional nature of pd\_prune\_xid

pd\_prune\_xid is updated non-transactionally. It implies that it may not be consistent with the actual lowest prunable tuple in the page. Currently, postgres assumes that the transaction will be commited to compute the value of pd\_prune\_xid. In this initial version, we don't intend to improve on this. The goal is to provide a fully consistent histogram regarding existing pd\_prune\_xid values.


<a id="org1d8f9b9"></a>

## Moving from per-backend stats to shared stats

Being non transactional makes for a more direct flow from data collection up to shared pgstats. We collect data into an transient histogram in the per-backend pgstats. Then, on pg\_relation\_flush we transfer data from the transient histogram to the final histogram in shared pgstats.

It is also at this moment that we balance the shared histogram, eventually merging some bins.


<a id="orgbfd44a2"></a>

## Histogram balance

We balance the shared histogram in two situations: (1) the counter of the highest bin is too high;  (2) **oldest\_nonremovable** is higher then the second upper bound.

The transient histograms are always initialized with the shared histogram bounds. During the lifetime of a transient histogram, the shared histogram may be balanced. So, at the moment of merging back the transient into the shared histogram we need to be careful to not introduce additional inconsistencies.


<a id="org62985bc"></a>

## Histogram merging

When moving freqs from the transient into the shared histogram there are two special cases to pay attention: (1) two or more intermediate bins in the shared histogram were merged into one bin; (2) the highest bin was split into two or more bins.

Case (1) is not really a problem. We are fitting high resolution data into a lower resolution grid.

The situation is quite the opposite in (2): the highest bin from the transient histogram covers one or more bins in the shared histogram. There is no way make this operation without loosing information. But if we do it carefully, we can guarantee some useful properties. In particular, we want to use the shared histogram to answer "How many page can be pruned now?". And we will be able to say "**At least** N pages can be pruned now."

In order to guarantee this lower bound, at the moment of moving the freqs from one bin into two or more bins, we need to choose the highest overlapping bin in the target histogram. This means that we may consider some pd\_prune\_xid's to be higher than their actual value, but never the opposite. The situation is a little bit trickier because we can have negative counts in the transient histograms. In these cases, we should consider the lowest overlapping bin in the target histogram.

So, in order to handle positive and negative counts in the transient histogram, we have an additional counter for the negative counts of the highest bin. We don't need to handle separetely the intermediate bin freqs.


<a id="orgdcc9d1d"></a>

## Final Solution

The user can simply query pgstats to have an updated view of how many pages are prunable now and later.

