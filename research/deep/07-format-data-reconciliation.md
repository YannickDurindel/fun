# 07 - Format benchmark data reconciled (Instagram and X)

Date of research: 2026-11-16. Grades: P = primary (vendor's own report/page, fetched), S = secondary (someone else summarising, or a search-result snippet only), U = unverified. Every number below came from a page fetched in this session unless marked "snippet only" or "not fetched". "Vendor" datasets are not peer-reviewed.

## 0. Bottom line

1. The Reels-vs-carousel-vs-image "winner" flips with the denominator. Per reach, Buffer has carousels best (6.9% vs Reels 3.3%). Per follower (likes+comments), Socialinsider has carousels narrowly ahead (0.55% vs 0.52%). Per view, Dash Social says Reels win (2.7% vs carousels 1.4%). These are not contradictions; they measure different things. Reach (distribution) is where Reels reliably win, especially to non-followers.
2. Under 10k followers the format gaps are small and noisy; only one vendor (Fanpage Karma) reports reach by size band, and it supports "Reels for reach."
3. Posting more is associated with faster follower growth, but with sharply diminishing returns and a small absolute effect (Buffer, 102K accounts).
4. On X, the best-sourced finding is that Premium accounts get roughly 10x median impressions and that non-Premium median engagement has hit 0% (Buffer, observational). Evidence for threads vs single posts and for a link penalty is weak or absent.
5. No vendor dataset isolates causation. Everything here is correlational, from tool users.

## 1. The datasets (what each actually measures)

| Vendor | Report (date) | Sample | Period | Engagement-rate (ER) definition | Small-account segment | Grade |
|---|---|---|---|---|---|---|
| Buffer, format ER | State of Social Media Engagement 2026 (page dated 2026-03-19) | "Millions of posts"; no total or per-format n for IG format ER; Stories n=520 | 2025 data | Median ER as % of reach (engagements / reach) | None | P |
| Buffer, IG reach | Reach vs engagement analysis (2024-10-23) | 4M+ posts sent via Buffer | Jan 2022 - Oct 2024 | Instagram's own definition of engagement and reach; medians | None | P |
| Buffer, IG frequency | How often to post (2025-08-13) | 2.1M feed posts, 102K accounts | Not stated | Follower growth rate, within-account fixed effects and z-scores | None (5K account is a hypothetical) | P |
| Buffer, IG timing | Best time (page says Sep 2026) | 9.6M posts, 200K+ accounts | Jan 2024 - Dec 2025 | (likes+comments+shares+saves)/followers x100, median | None | P |
| Buffer, X Premium | X Premium review (2025-10-02) | 18.8M posts, 71K accounts (~27% Premium) | Aug 2024 - Aug 2025 | Likes+replies+reposts; denominator not defined | None | P |
| Buffer, X vs Threads | (2025-02-03) | 10.2M posts | 2024 | Interactions / reach or impressions, median | None | P |
| Buffer, X/Threads/Bluesky | (early 2025) | 1.7M posts, 56K users | Early 2025 | Raw engagements per post (not a rate) | None | P |
| Socialinsider | 2026 Instagram Organic Benchmarks (published 2026-02-20, modified 2026-11-04) | 67.5M posts, ~579K business accounts; page says accounts 1K-1M | Page says Jan 2024 - Dec 2026 but also says "2026" labels are really 2025 values | (likes+comments)/followers x100; saves/shares excluded | Yes: <5K and 5K-10K | P |
| Socialinsider | Reel length study (data Jan-Jun 2026) | 9.77M Reels | Jan-Jun 2026 | Likes+comments / followers | Buckets exist but no per-size results | P |
| Metricool | Instagram study press release (2026) | 24.36M posts, 375K accounts | Jan-Feb 2025 vs Jan-Feb 2026 | Not defined | Only "21% of accounts under 10k grew" | P (press release) |
| Fanpage Karma | Format reach by account size (undated; related posts to Nov 2026) | 3M+ posts | Jan - Apr 2026 | Median reach as share of followers | Yes: <10K | P |
| Rival IQ / Quid | 2026 benchmark (Mar 2026) | 150 companies per industry from a 200K+ database; organic and paid mixed | 2024-2025 | Total interactions / followers | None | P |
| Dash Social | 2026 H1 Instagram benchmark | Not retrievable (PDF over 10MB limit); press release gives none | Press release dated 2026-04-28 | Engagements / views (per search snippet, PDF not fetched) | None found | S |
| Emplifi | Benchmarks page (Q4 2025 data) | "Thousands of brand accounts" | 2024-2025 | Not defined on page; search snippet says Q3 2026 switched to interactions/impressions (snippet only) | None | P / S |
| Ordinal | X engagement study (to May 2026) | n not stated; skews to B2B/startup, high-volume accounts | Jan 2024 - May 2026 | (likes+replies+reposts+quotes)/impressions, median | Not covered | P (weak) |

Not obtained: Later, HubSpot, Sprinklr, Sprout Social original datasets. The only Sprout page fetched (2026-01-15) contained no original format, hashtag or frequency data, only a citation of the 2025 Sprout Index (single-image share down 7 points since 2023). Hootsuite's 2026 Social Trends is a survey of 6,500+ marketers (snippet only); no Hootsuite benchmark data was fetched. Search budget ran out before I could pursue these, so absence here is "not found", not "does not exist".

## 2. Instagram: format comparison

| Metric | Reels | Carousel | Single image | Source and definition | Grade / date |
|---|---|---|---|---|---|
| ER, % of reach | 3.3% | 6.9% | 4.4% | Buffer, 2025 data | P, 2026-03 |
| ER, % of followers (likes+comments) | 0.52% | 0.55% | 0.37% | Socialinsider, 2025 | P, 2026-02 |
| Same, later quarter | 0.48% | 0.50% | 0.35% | Socialinsider "Q3 2026" column (page inconsistent about labelling) | P, 2026-11 |
| ER on views | 2.7% | ~1.4% | ~1.3% | Dash Social H1 2026 | S (snippets, PDF not fetched) |
| Reach vs Reels | 1.0x | 0.74x (Reels = 1.36x carousel) | 0.44x (Reels = 2.25x image) | Buffer 2022-2024 | P, 2024-10 |
| Engagement vs carousel | about -11% | baseline | -53% (carousel 2.14x) | Buffer 2022-2024 | P, 2024-10 |
| Median reach per follower per post, <10K | 4.9% | 2.6% | 3.5% | Fanpage Karma, Jan-Apr 2026 | P, undated |
| Interaction rate, <10K | 0.34% | not reported | 0.51% | Fanpage Karma | P |
| Reach to existing followers, <10K | 2.0% | not reported | 2.1% | Fanpage Karma | P |
| Interactions vs image | >4x | higher (no multiplier) | baseline | Metricool | P, 2026 |
| Saves vs image | not reported | 9x | baseline | Metricool | P, 2026 |

Small-account segment, Socialinsider 2025 (per-post medians, rounded by the vendor): 1-5K accounts get views Reels 580 / carousels 993 / images 417, comments 3/2/1, saves 1/1/1. 5-10K accounts: views 1,000 / 2,117 / 1,068, comments 6/4/1, saves 2/2/1. P, 2026-02. The vendor itself calls the format gap "relatively modest" for small brands.

### Reconciling the disagreements

- Reach vs engagement is a real trade-off, not noise. Buffer (2024) and Fanpage Karma (2026) both say Reels reach more people; Buffer also says carousels convert reached viewers better. Both are consistent with the format-level picture of Reels as discovery and carousels as depth.
- Views vs reach: Socialinsider's table has carousels with more views than Reels for under-10k accounts (993 vs 580; 2,117 vs 1,000), which contradicts Fanpage Karma's reach-per-follower ranking (Reels 4.9% vs carousels 2.6%). I cannot resolve this: different samples (brand/business accounts vs. unknown), different metrics (views include repeat views and, for carousels, multiple impressions per swipe; reach is unique accounts), different periods. Treat "which wins for tiny accounts" as unresolved. Grade: U on the ranking, P on the existence of the conflict.
- Denominators: Rival IQ's all-industry IG median of 0.30% (interactions/followers, organic+paid, mixed formats) and Socialinsider's 0.48% (likes+comments/followers, business accounts) are the same family; Buffer's 3-7% is per reach; Dash's 2.7% is per view. Never compare across them. Buffer's own 2026 page lists IG median ER falling from about 7.3% (2024) to 5.4% (2025), -26% (P, 2026), while Buffer's Sep 2026 timing page uses a per-follower definition: even one vendor mixes definitions.
- Trend direction agrees across vendors: single images are declining (Socialinsider 0.45% to 0.37%; Metricool image reach -21.96%, engagement -45.98% YoY; Sprout Index -7 points of mix). Overall ER is also declining (Rival IQ -17%, Buffer -26%, Socialinsider roughly -4% on its own table, although its text says -24%; that internal inconsistency is flagged on the page).
- Data-quality red flags: the Socialinsider page claims Jan 2024-Dec 2026 and exclusion of accounts under 1K/over 100K but includes a 100K+ bucket; segment counts do not sum to the stated total. Metricool's press release does not define "engagement". Buffer's reach page does not report per-format counts. Fanpage Karma's article carries no date.

## 3. Instagram: other levers

### Posting frequency and growth

Buffer (2.1M feed posts, 102K accounts, published 2025-08-13, within-account fixed-effects model): growth-rate increase of +0.12% (1-2 posts/week), +0.26% (3-5), +0.44% (6-9), +0.66% (10+), versus posting nothing. Reach per post vs 1-2/week: +12% (3-5), +18% (6-9), +24% (10+). Posting nothing has a z-score of -0.08. P, 2025-08. The article's illustration for a hypothetical 5K account: 3-5 posts/week is about 13 extra followers per week. So the effect is real but small; returns per extra post shrink. Limits: Buffer users only, period not stated, formats pooled, no small-account result.

Conflicting signals: Dash Social's press release says brands average eight posts/week and those posting fewer than six per week see 93% higher engagement (P as a claim, S for method since no sample given; engagement per post naturally falls when volume rises, so this is not a contradiction of Buffer's growth finding). Rival IQ's median brand posts 3.69 times/week on IG (P, Mar 2026). Socialinsider reports ~8 Reels, 5 carousels and 7 images per brand per month in 2025 (about 5 posts/week), with no frequency-growth analysis (P).

Best estimate for under-10k: 3-7 feed posts/week mixed formats is where sustained growth gains are documented; no dataset shows a break-even above 10/week for small accounts. Grade: S (inference from pooled data).

### Reel length

Socialinsider, 9.77M Reels, Jan-Jun 2026, likes+comments/followers: 0-30s 0.28% (median views 4,700); 30-45s 0.30% (8,564); 45-60s 0.35% (10,374); 60-90s 0.30% (9,790); 90-120s 0.30% (8,000); 120-180s 0.33% (9,000); 180s+ 0.15% (4,428). P, 2026. No per-size breakdown; the vendor attributes the 180s+ drop to non-followers not being recommended Reels over 3 minutes (their explanation, not tested). Metricool reports average Reel watch time of 8.5 seconds, more than double YoY (P, 2026). Gaps are small between 30 and 180s; the finding is "avoid under 30s and over 3 min", not "60s is optimal". Survivorship note: longer Reels are posted by accounts that can hold attention.

### Hashtags

- Metricool (24.4M posts): posts with at least one hashtag had 31.70% fewer views and 33.89% fewer interactions than platform average. P, 2026; correlational (accounts that spam hashtags are probably different accounts).
- Instagram cut the hashtag limit from 30 to 5 for posts and Reels (Social Media Today, 2025-12-18, rollout gradual, says Instagram stated fewer targeted tags work better) and reports Mosseri saying in Feb 2025 hashtags "don't work" for reach and in May 2025 that they do not improve visibility but show what a post is about. S (reported by trade press; I did not fetch an Instagram primary post), 2025-12.
- Best estimate: 0-5 hashtags, no reach benefit expected; use for topic labelling only. Grade S.

### Posting time

Buffer 9.6M posts (Sep 2026): top slots Thu 9am, Wed 12pm, Wed 6pm; overnight lowest; no effect sizes or significance tests reported, normalised to local time, Buffer users only. P that the report exists; effect size U. Treat as tie-breaker only. For a faceless alpine page with a global audience, time-zone mix probably matters more than the vendor curve (my inference, U).

### Caption length

No large dataset found. A Hootsuite two-day experiment (search snippet only, not fetched) was described as inconclusive. Metricool reports posts with a question got 36.70% more comments and posts with a comment-focused call to action 202.78% more comments (P, press release, 2026; "more" is vs. an unstated baseline). U for any ideal length.

### Non-follower distribution

Dash Social press release (2026-04-28): Instagram views from non-followers rose from 30% to 49% (years not named; no sample size). S/P-weak. Fanpage Karma agrees directionally for small accounts: Reels reach nearly three times as many non-followers as carousels (no exact figures).

### Growth by account size

Socialinsider (business accounts): average annual follower growth 1-5K: 38% (2024) to 22% (2025); 5-10K: 35% to 20.29%. P. This is an average over survivors who stayed on the platform and kept posting; it overstates what a typical new page experiences. Metricool: only 21% of accounts under 10K grew in 2026 (P, press release; definition of "grew" absent). These two numbers pull in opposite directions and the gap likely reflects who is in the sample.

## 4. X (Twitter)

| Metric | Figure | Source | Grade / date |
|---|---|---|---|
| Median ER by post type (2025) | Text 3.56%, images 3.40%, video 2.96%, links 2.25% | Buffer, % of reach, Buffer users | P, 2026-03 |
| Median ER, X overall (2024) | 3.6% | Buffer 10.2M posts | P, 2025-02 |
| Median raw engagements per post | 4 (Feb 2025); mean ~328 | Buffer 1.7M posts, 56K users | P, 2025 |
| Media vs text (Ordinal) | Text-only ~35,975 impressions at ~0.68% ER; image ~18,334 at ~0.79%; video ~0.54% | Ordinal, B2B-skewed, n not stated | P (weak), 2026 |
| Median impressions by tier | Regular under ~100; Premium ~600; Premium+ over ~1,550 | Buffer, 18.8M posts | P, 2025-10 |
| Median ER by tier | Regular 0% (from Mar 2025); Premium ~0.49%; Premium+ ~0.53%; Basic ~0.55% | Buffer | P, 2025-10 |
| Rival IQ X median ER | 0.03% (2025) vs 0.015% (2024); likely 2.24 posts/week (not explicitly labelled X) | Quid/Rival IQ | P, 2026-03 |
| Overall median reach | fell from ~1,000 (Aug 2024) to under 750 (Aug 2025) | Buffer | P, 2025-10 |

Reconciliation: Buffer's 3% figures are per reach/impression on Buffer-user accounts; Rival IQ's 0.03% is per follower on company accounts. A hundredfold gap from definitions alone. Ordinal's 0.68-0.79% sits between because of its impression denominator and high-volume B2B accounts. Buffer's X ER stacking (text > image > video > link) conflicts with Ordinal (image > text > video on rate), but agrees that links are worst (Buffer) and that text-only gets more impressions (Ordinal). Because the two disagree on text vs image, treat this as a tie.

Premium: Buffer is observational, does not control follower count in the figures shown, does not describe how the sample was drawn, and notes a median of 0% means at least half of regular accounts got no likes, replies or reposts on a typical post. It does not isolate the checkmark from account activity. Academic corroboration is thin: Efstratiou, Duskin, Starbird and Spiro (arXiv 2512.06129, Dec 2025) study pre-X Twitter and report that legacy-verified accounts got less algorithmic exposure than non-verified or Twitter-Blue-verified accounts; the abstract page reports no effect sizes, sample or window (P for the direction, effect size U; it is about pre-rebrand Twitter, so partly outdated). I did not verify Premium's causal effect on reach on current X.

Posts per day: no dataset found. Buffer's X advice (3-5 or 3-4 posts/day, two figures on the same site) cites only a 30-account sample with no results per frequency (P that it is unsupported). Buffer's state report mentions a 15.7M-post frequency/engagement study and a 4.8M channel-week growth study covering Facebook, Instagram and X, but I could not retrieve the X results (two guessed URLs returned HTTP 500; search budget exhausted). Not found. Grade U for any posts/day figure.

Threads vs single posts: no independent dataset found; vendor claims (3x etc.) came from search snippets with no sample sizes. Grade U. Link penalty: Buffer's link ER is lowest (2.25%, and 0% for regular accounts after March 2025 per its Premium analysis); no study isolates cause. S.

## 5. Methodological limits

- Vendor bias: every dataset comes from users of that vendor's tool; Buffer says explicitly its data is only Buffer-posted content. Business/brand accounts, scheduled content and tool-using creators differ from anonymous niche pages.
- Survivorship: Buffer requires 10+ posts across 4+ weeks in a year; Socialinsider averages growth over profiles that remained. Dead or abandoned pages are absent.
- Correlation: Buffer's fixed-effects frequency model is the best causal-leaning design here, yet it still cannot rule out that accounts post more when things are going well.
- Median vs mean: Buffer uses medians; Socialinsider averages. On skewed distributions (X median 4 engagements vs mean 328) this alone explains large differences.
- Definition drift: Emplifi snippet reports a metric switch in 2026; Buffer mixes definitions; Socialinsider labels 2025 data as 2026.
- Time: Instagram changed its metrics in 2026 (Socialinsider says views replaced impressions) so 2024-2025 and 2026 comparisons are shaky.
- Sample sources rarely include n per format or per size band.

## 6. Best-estimate ranges for accounts under 10k followers (as of 2026-11-16)

| Metric | Estimate | Grade | Note |
|---|---|---|---|
| IG ER, likes+comments / followers, all formats | 0.3-0.6% | S | Socialinsider 0.37-0.55% by format, Rival IQ 0.30% median (mixed brands) |
| IG Reel reach per follower per post | ~3-5% | S | Fanpage Karma 4.9% for <10K; one source, one season |
| IG carousel reach per follower per post | ~2-3% | S | Fanpage Karma 2.6%; conflicts with Socialinsider view counts |
| IG image reach per follower per post | ~3.5% | U | Fanpage Karma only |
| IG saves per post | 1-2 median | S | Socialinsider; vendor rounds to integers; no sharing data |
| IG feed posts/week for growth | 3-7 | S | Buffer; diminishing returns |
| IG Reel length | 30-180s; avoid <30s and >180s | S | Socialinsider; effect gaps small |
| IG hashtags | 0-5, no reach benefit | S | Instagram limit 5; Metricool negative correlation |
| IG best time | Wed/Thu, evenings; weak effect | U | No effect sizes reported |
| X median ER per impression | ~0.5-3.5% depending on metric; free accounts may be near 0% | S | Buffer, Ordinal; definitions vary |
| X median impressions per post, non-Premium | under ~100 | S | Buffer, mixed sizes |
| X Premium impressions multiple | ~6-15x median (observational) | S | Buffer, 2025-10; causal share unknown |
| X posts/day | no evidence-based figure | U | |
| X threads vs single, media vs text | no reliable estimate | U | |

## 7. Implications for us

Do:
- Make Reels the discovery format (reach, non-followers), 30-180s, and use carousels (saves, depth) alongside; run our own A/B on both because published small-account rankings conflict.
- Aim for 3-7 feed posts/week and treat 10+ as optional upside with small returns; consistency matters more than volume (zero posting is the only clearly bad level).
- Use 0-3 targeted hashtags or none; do not rely on them for reach.
- Track our own reach per follower, saves per reach, and share rate, using Instagram Insights (the only trustworthy source for our own account).
- On X, expect very low impressions for a free account (vendor median under 100); treat Premium as a testable hypothesis, not a proven lever, and A/B it by tracking median impressions before and after on our own account.

Do not:
- Do not quote any single ER number without its denominator.
- Do not build strategy on threads-beat-singles, link-penalty magnitudes, or "N posts/day" claims; none has a retrievable dataset.
- Do not use vendor best-time charts as schedule rules.
- Do not treat Socialinsider's 20-38% growth rates as a growth forecast for a new page.

Open items to follow up: Later, HubSpot, Sprinklr, Sprout and Hootsuite datasets (not retrieved); Buffer's X posting-frequency study; Dash Social's full PDF; Emplifi's per-size charts.

## Sources (all fetched via WebFetch on 2026-11-16 unless noted)

- Buffer, Best content format 2026: https://buffer.com/resources/data-best-content-format-social-media/
- Buffer, State of Social Media Engagement 2026: https://buffer.com/resources/state-of-social-media-engagement/
- Buffer, IG posting frequency: https://buffer.com/resources/how-often-to-post-on-instagram/
- Buffer, IG reach vs engagement: https://buffer.com/resources/instagram-reach-engagement-analysis/
- Buffer, best time on Instagram: https://buffer.com/library/when-is-the-best-time-to-post-on-instagram
- Buffer, X Premium review: https://buffer.com/resources/x-premium-review/
- Buffer, Threads vs Twitter: https://buffer.com/resources/threads-vs-twitter/
- Buffer, X/Threads/Bluesky 1.7M posts: https://buffer.com/resources/x-threads-bluesky-data/
- Buffer, how often to tweet: https://buffer.com/resources/how-often-should-i-tweet
- Fanpage Karma, format reach by account size: https://www.fanpagekarma.com/insights/instagram-format-reach/
- Socialinsider benchmarks: https://www.socialinsider.io/blog/instagram-benchmark-report/ ; https://www.socialinsider.io/blog/instagram-carousel-posts-study/ ; https://www.socialinsider.io/blog/instagram-hashtag-study/ (page contains no hashtag data despite its URL)
- Socialinsider, Reel length: https://www.socialinsider.io/blog/instagram-reels-length/
- Metricool 2026 Instagram study: https://metricool.com/press-release-instagram-study-2026/
- Quid / Rival IQ 2026: https://www.quid.com/knowledge-hub/resource-library/blog/2026-social-media-industry-benchmark-report
- Dash Social press release: https://www.aap.com.au/aapreleases/globenewswire9708696/ ; Instagram PDF (not fetched, exceeded size limit; figures from search snippet only): https://pages.dashsocial.com/hubfs/social-media-benchmark/2026/H1/instagram.pdf
- Emplifi: https://www.emplifi.io/resources/reports/social-media-benchmarks/
- Sprout Social: https://sproutsocial.com/insights/instagram-reach/
- Ordinal X study: https://www.tryordinal.com/blog/twitter-x-engagement-data-study
- Social Media Today on hashtag limit: https://www.socialmediatoday.com/news/instagram-implements-new-limits-on-hashtag-use/808309/
- Efstratiou et al., arXiv:2512.06129 (abstract page only): https://arxiv.org/abs/2512.06129
- Not fetched (search snippets only): Hootsuite caption experiment https://blog.hootsuite.com/experiment-what-reels-caption-length-gets-the-best-engagement ; Hootsuite Social Trends 2026 https://www.hootsuite.com/research/social-trends
