
# Table of Contents

1.  [Solving the Useless Vacuum Problem](#org29b8abc)
    1.  [Solution](#orgbe4c714)
        1.  [A Proven Lower Bound](#orgbe30a07)
    2.  [Xid Histogram Flow and Dead Tuples Lifecycle](#orgf0c633a)
        1.  [Main Shared Histogram](#org408147d)
        2.  [Per-backend histogram](#org6d81df0)
        3.  [Vacuum histogram](#orga5c646f)
        4.  [Conclusion Regarding Xid Histogram Flow](#orgb468efc)
    3.  [Histogram Spec](#org5d25236)



<a id="org29b8abc"></a>

# Solving the Useless Vacuum Problem

The scope is to keep track of dead tuples xid of each relation so that we can estimate the number of removable dead tuples in a vacuum operation. In particular, the estimate provided is a proven lower bound of the actual number of removable dead tuples.


<a id="orgbe4c714"></a>

## Solution

We add 2 fields in PgStat\_StatTabEntry to represent a histogram of dead tuples xids. This histogram has 5 bins, so each of these fields is an array of 5 elements. Like the other information in this struct, this histogram is shared across all backends and is persisted through proper restarts. We also make use of auxiliary histograms in other places in order to consolidate dead tuples xid info before feeding into the main histogram. The auxiliary histograms do not need to have the same number of bins as the main histogram.

We use auxiliary histograms in PgStat\_TableCounts and LVRelState. The former keeps track of dead tuples added/removed per transaction (note that there may be many xid per transaction), while the latter keeps track of dead tuples removed during vacuum.


<a id="orgbe30a07"></a>

### A Proven Lower Bound

When collecting xid information to insert into the histogram, we cannot know the exact dead tuple xid (or we don't want to pay the price to find out). However, we can easily compute a xid range for a single dead tuple. So, when we add/remove a dead tuple with a xid range into the histogram, there will possibly be more than one bin for which the ranges overlap. We adopt the following method: when adding a dead tuple, consider the highest overlapping bin; when removing a dead tuple, consider the lowest overlapping bin. Then, the cumulate distribution of the computed histogram remains a lower bound of the cumulate distribution of the underlying real data.

In a successive step, when merging auxiliary histograms into the main histogram, there is an analogous situation. But instead of adding/removing a single dead tuple xid, we are adding/removing a batch of dead tuples with identical xid ranges.


<a id="orgf0c633a"></a>

## Xid Histogram Flow and Dead Tuples Lifecycle


<a id="org408147d"></a>

### Main Shared Histogram

This is the final histogram stored in PgStat\_StatTabEntry. It is updated with a lock by (1) pgstat\_report\_vacuum and (2) pgstat\_relation\_flush\_cb with data from vacuum histogram and per-backend histogram.

1.  From per-backend histogram

    The update happens on a periodical flush, which can also be triggered manually. Assuming that the respective transactions didn't touch all pages of the relation, we may expect that the negative freqs from per-backend histogram do not zero out any bin in the main shared histogram. Further, we expect to increase freqs and bounds of the higher bin. Due to bin bounds mismatch, it is possible that some bins finally stay negative, and this is ok.

2.  From vacuum histogram

    It happens at the end of a vacuum process, just after computing vacuum stats histogram. We expect that negative freqs from vacuum stats histogram do zero out some bins in the main shared stats.


<a id="org6d81df0"></a>

### Per-backend histogram

It is initialized by &#x2026;

It is updated by (1) pgstat\_update\_heap\_dead\_tuples in the middle of a transaction and by (2) AtEOXact\_PgStat\_Relations at the end of a transaction.

1.  Removing Dead Tuples

    The function heap\_page\_prune\_opt removes dead tuples when it is convenient, and this happens in the middle of a transaction. So, we start by inserting negative freqs in the per-backend histogram. Moreover, the order of the successive xids is completely random.

2.  Adding Dead Tuples

    Only after a COMMIT/ROLLBACK command can we determine which tuple is dead. So, at the end of the transaction we insert positive freqs in the per-backend histogram. We can expect that the successive xids are roughly ordered, usually increasing the histogram highest bound.


<a id="orga5c646f"></a>

### Vacuum histogram

It is initialized by &#x2026;

It is updated by (1) lazy\_scan\_prune during vacuum.

1.  Removing Dead Tuples

    Vacuum can only remove dead tuples, so it will insert negative freqs in random order starting with a fresh histogram.


<a id="orgb468efc"></a>

### Conclusion Regarding Xid Histogram Flow

The fact that we start, in both per-backend and vacuum histograms, by removing dead tuples in a completely random order poses a problem to the current histogram implementation: there is no way to incrementally define bin bounds when successively inserting items in a random order. Well, it is technically possible, but one cannot expect a well-balanced histogram.

As a solution to this problem, at the beginning of every vacuum/per-backend histogram building, we will initialize the bounds with the bounds of the main shared histogram. Furthermore, we will not update the bounds of the vacuum/per-backend histogram. This solution brings 2 beneficial side-effects: (1) when transferring the information to the main shared histogram, the bounds are aligned, reducing information loss due to mismatch; (2) updating the bounds is an expensive operation, and we will not perform it in the critical paths. Note that we can bypass updating the bounds during vacuum/per-backend histogram building only because we have a guarantee of the histograms bounds alignment, otherwise we would loose too much information.


<a id="org5d25236"></a>

## Histogram Spec

Each item in the array **bounds** is a inclusive upper bound of the respective bin. If the value is 0, it means the bin is not active and should not be considered. We fill the arrays from right to left, so the inactive bins, when they exist, are on the left.

When adding positive **freqs** (creating dead tuples), the rightmost bin is special: its upper bound should be updated if the new dead tuple has a higher bound than previous one. It means that the histogram has open bins on the extremes (the lowest bin is intrinsically open since it does not have a lower bound). However, it should be an error to add negative **freqs** if the new bounds is higher than the highest bound.

Inserting new **freqs** is a trivial operation: just need to find the proper bin looking at **bounds** array. What about updating the **bounds**? We rely on the fact that new dead tuples xid happen in an almost monotonically increasing order. So, we keep increasing the last bin until we decide it is big enough. At this point, we choose a couple of adjacent bins to merge. Then, we shift the remaining bins to the left, creating a fresh rightmost bin. We arrange these things in order to achieve a well balanced histogram. In practice, we only update the **bounds** of the main shared histogram.

