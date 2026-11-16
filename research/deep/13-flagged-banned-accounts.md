# 13. Flagged, restricted and banned accounts: what actually gets pages punished (as of 2026-11-16)

Project context: anonymous, faceless, AI-assisted pages. Instagram alpine facts/mood (Reels-first) and X Stoic.

Grading: **P** = primary (platform's own text, court filing, peer-reviewed), **S** = secondary (press, aggregator, reposting a primary), **U** = unverified/anecdotal or vendor claim. Every claim carries a date. "Fetched" means I read the page in this session.

## 0. Method and honest gaps

- About 30 searches/fetches were run. The shared web-search budget ran out before I could do dedicated Reddit/forum passes. Instagram, x.com and help.x.com returned 403 or were login-walled. PetaPixel pages returned 403 on fetch.
- **I found no documented, named case of a faceless alpine/mood Instagram page or a Stoic quote X page being banned.** Every case below is adjacent (aggregators, AI personas, automation, fake engagement, wrongful bans). Where I generalise to our niche, it is inference.
- No Reddit threads were fetched, so there are no Reddit-sourced cases here. Anecdotes come only from press quoting users.
- Almost no academic audit can prove a "shadowban" from outside the platform (see cross-cutting evidence in section 1).
- Several tertiary SEO/vendor sites surfaced in search (scheduler vendors, "buy followers" guides). I treat them as U and do not rely on them.

## 1. Case table

Columns: what the account did / trigger cited / penalty / reversal / evidence / date.

### Instagram and Meta

| # | Case | Trigger cited | Penalty | Reversal | Evidence | Date |
|---|------|---------------|---------|----------|----------|------|
| C1 | Aggregator / repost accounts (policy, not one account) | Mostly re-uploading others' photos, carousels (Reels already covered since 2024) | Ineligible for recommendations (Explore, feed suggestions); existing followers still see posts | Eligibility regained if a "substantial share" of posts over a rolling 30 days is original (not defined); appeal via Account Status | **P** Instagram Creators blog (fetched); **S** TechCrunch (fetched) | 2026-04-30 |
| C2 | Facebook repeat reposters (Meta statement, same direction on the sister platform) | "Reuses or repurposes another creator's content repeatedly without crediting them" | Reduced reach on all content, temporary loss of monetisation; ~500,000 accounts actioned for spam/fake engagement and 10 million impersonator profiles removed in H1 2025 | No appeals process described | **S** Influencer Marketing Hub (fetched; Meta's own post not fetched) | 2025-07 |
| C3 | AI-generated personas without a label | Profile features an AI-generated person and omits the new "AI-generated profile" label | Reduced reach ("may soon see limits") | Appeal via Account Status | **S** Engadget (fetched); rule is narrow, not about AI content in general | 2026-08-31 |
| C4 | Photographers labelled "Made with AI" after small edits (e.g. Generative Fill to remove a speck) | Meta's automatic AI detection | A label, later renamed "AI info" (Jul 2024) | Label wording changed; detection method undisclosed | **U/S** only from search-result summaries of PetaPixel (2024-05 to 2024-07); article fetch 403, **not fetched** | 2024-05/07 |
| C5 | Camille Hanson, English-teaching business, ~1M followers, run from Portugal | Alleged fraud and deception (auto flagged) | Facebook and Instagram accounts deleted | Appeal denied about a week later; Meta later said it was one of two mistaken bans among 5 accounts the NYT flagged; restoration not stated | **S** The Next Web and The Star (both fetched, relaying NYT, not fetched) | 2026-03 (reported 2026-07-21/22) |
| C6 | Athenia Rodney (JuneteenthNY) | Child-exploitation notice; accounts had been hacked | Six accounts banned | Restored only after NYT intervened | **S** TNW, The Star | 2025 to 2026-07 |
| C7 | Unnamed influencer | Copyright | Restored, banned again days later over copyright, reinstated again | Yes, twice | **S** TNW (anonymous, thin) | 2026 (reported 2026-07-22) |
| C8 | 100 pole-dance creators surveyed by Dr Carolina Are (LSE) | Recommendation-guideline flags shown in Account Status | Ineligible for Explore/non-followers | 65% said Account Status notifications did not help; 72% said the appeal did not help; "whack-a-mole" reflagging; unclear if appeals resolved | **P** peer-reviewed, Platforms and Society journal, via LSE news page (fetched; the PDF itself was unreadable) | 2026-02-26 |

### X

| # | Case | Trigger cited | Penalty | Reversal | Evidence | Date |
|---|------|---------------|---------|----------|----------|------|
| C9 | ~4,000 Revenue Sharing accounts | Posting engagement bait ("I'll follow everyone who replies") 3+ times; reposting others' work; artificial engagement; evading detection | Removed from rev share, referred to policy team for possible suspension; Grok flags it | None reported | **S** Digg embed of Bier's post (fetched), Innovation Village (fetched, 2026-07-20). Bier's post not fetched directly | 2026-07-16 |
| C10 | Stolen/duplicate content | Reposts, even with watermarks, new intros or minor edits | Impressions redirected to original creator; X says 1.5M posts identified, >$1M redirected | n/a | **S** Innovation Village (X figures second-hand) | 2026-07 |
| C11 | 42,000 accounts automating replies with chatbots | "AI that engages users without a human in the loop" | Removed from platform, "no warnings, no grace period" | None mentioned | **S** Startup Fortune quoting Bier (fetched; his post not fetched) | 2026-07-25 |
| C12 | @heygurisingh plus 3 unnamed friends | Reply automation with AI agents; Bier said proofreading/grammar help is fine, autonomous agents posing as organic engagement are "strictly forbidden"; summoning Grok is fine | Suspended | Not mentioned | **S/U** PiunikaWeb (fetched); user-reported | 2026-05-28 |
| C13 | Wave of "inauthentic behavior" suspensions | Notices cite "aggressive and random repost and/or liking", "indiscriminate following"; Bier warned (Feb 14) that accounts not operated by a human tapping a screen could be suspended; tighter API rules on automated replies | Suspensions, some on near-passive accounts; one user claims a 249,000-follower account out for 4+ months | Bier later: spam-filter bug, ~12 hours, ~99% of wrongly suspended accounts restored; users say appeals are rejected within seconds and some "restored" emails did not restore access | **S** PiunikaWeb (fetched); Bier numbers second-hand; user stories **U** | 2026-03 |
| C14 | April ban wave | Not confirmed; speculation around spam aimed at Japan; Bier reportedly said 208 bots/minute removed | Suspensions, follower-count drops | No figures for April | **S/U** roboin.io (fetched, low-grade site) | 2026-04-05/10 |
| C15 | Reward-for-posting "InfoFi" apps (Kaito, Cookie DAO, Xeet) | API now bars tokens/points/cash for engagement | API access revoked, projects paused or sunset | None | **S** The Block (fetched) | 2026-01 |
| C16 | X v. Vivek Kumar Sen and Zamyang Sherpa | Six accounts run as one network, near-identical posts seconds apart, mutual likes, booster accounts, mismatched Stripe payees | Nine accounts suspended Aug 18; London High Court claim filed Sep 17 for at least £207,384 (about $278,000) plus about £75,000 investigation costs | Pending; no defence filed as of 2026-09-21 | **S** Decrypt describing the filing (fetched); court docs not fetched | 2026-09-17 |
| C17 | Creators posting unlabelled AI armed-conflict video | Missing AI disclosure | 90 days out of Revenue Sharing; repeat = permanent | Not mentioned | **S** eWEEK (fetched; cites TechCrunch and Guardian, not fetched) | 2026-03-05 |

### Cross-cutting evidence

- **Shadowbans are not measurable from outside.** The LSE study measures creator perception, not reach. The Information Democracy shadow-banning report (Oct 2025) came up in search with a claim that technical barriers block robust quantitative proof, but the PDF was unreadable on fetch: **U**.
- **Meta's AI moderation.** TNW/Star (2026-07): a Meta spokesperson said new tools make 13% fewer mistakes than humans and find 10% more violations, and that all five NYT-flagged bans came from older tools. Of the five: two hacks (reversed), one legitimate, two mistakes. A petition with 60,000+ signatures exists, but its organiser sells recovery services (conflict of interest, noted by The Star). **S**.
- **X rev-share spam data.** Bier (2026-03, via Tech-ish, fetched): paid users are 2x more likely to be flagged as spam; flag rate is 100x higher when a paid user replies cross-border. **S**.

## 2. What the pattern says

1. **Most penalties on "pages like ours" are distribution penalties, not bans.** Instagram's originality rule removes recommendation eligibility only, and X's removals are from monetisation (C1, C9). If a faceless page is judged unoriginal, the symptom is a reach cliff for non-followers, with no notice other than Account Status.
2. **Automation on X is judged by behaviour, not tool.** What is stated as forbidden: autonomous AI replying, scripted engagement, non-human operated accounts. What is stated as fine: proofreading, summoning Grok (C12, C13). This comes from Bier's statements via press, **S**; I could not fetch X's own rules page (403).
3. **False positives are real and appeals are weak** (C5, C8, C13). Reversal is more likely when the cause is a platform bug, a hack, or press attention than when you plead on the merits.
4. **Monetisation programmes are stricter than the platform.** Under X Original Content Rewards (from 2026-09-08), content "created or posted by automated means" is ineligible, and copied, lightly edited, aggregated, or "thin summary" content does not qualify. Rejected applicants appeal once, then can reapply after 90 days (International Finance, fetched, **S**). Eligibility needs 500 verified followers and 500,000 Home Timeline impressions from verified users in 90 days, per that article. Other outlets gave conflicting thresholds (search snippets, **U**).

## 3. Triggers ranked by evidence

Strength: A = platform statement plus at least one documented enforcement; B = platform statement or multiple press reports; C = anecdote/vendor only.

| Rank | Trigger | Platform | Strength | Basis |
|------|---------|----------|----------|-------|
| 1 | Mostly re-posting or lightly edited third-party content | IG, FB, X | A | C1, C2, C9, C10 |
| 2 | Engagement bait ("reply and I'll follow") 3+ times | X | A | C9 |
| 3 | Autonomous AI/bot replies, no human in loop | X | A | C11, C12 |
| 4 | Coordinated multi-account networks for payouts | X | A | C16 (court case) |
| 5 | Scripted behaviour/"not human tapping" (mass likes, follows, reposts) | X | B | C13 (plus false-positive risk) |
| 6 | Undisclosed AI-generated person profile | IG | B | C3 (just announced, no enforcement cases found) |
| 7 | Unlabelled AI conflict video | X (monetisation) | B | C17 |
| 8 | Copyright claims, including re-bans after reinstatement | IG | C | C7 (one anonymous case); music-licensing guidance only from vendors (not graded) |
| 9 | Bought followers, engagement pods | IG | C | only vendor/agency blogs surfaced, no documented case; Meta cites "fake engagement" for the ~500,000 actioned accounts in C2 |
| 10 | Third-party schedulers | IG/X | C | vendor blogs say official-API schedulers are safe and password/browser tools are risky; no documented case |
| 11 | Faceless/anonymous per se | IG/X | none | no source says anonymity is penalised |
| 12 | AI-assisted imagery per se (non-person) | IG | none found | rule in C3 covers AI personas only; C4 shows false-positive labels |

## 4. What to never do (checklist)

- Never post content whose main value is someone else's image, clip or screenshot, even credited or watermarked (C1: credit, watermark, frame, speed change do not count).
- Never write "reply and I'll follow", "like for like", or similar solicitations on X (C9).
- Never let a bot or AI agent reply, quote or follow without a human deciding each action (C11, C12). Do not summon-and-forward at scale either: this part is my inference.
- Never run multiple accounts as a coordinated network to cross-boost, or take payouts through mismatched payee accounts (C16).
- Never use password-login or browser-automation tools on either account. Use only official-API schedulers (vendor claim, **U**, but consistent with Bier's "human tapping" line).
- Never buy followers or join pods (no documented case, but cheap risk for a page with no upside; Meta lists fake engagement as a removal category, C2).
- Never present an AI-generated human as real. For AI imagery or video, label it where the platform asks (C3, C17).
- Never evade a suspension with a new account (X rule quoted in search results, X help page not fetched: **U**).
- Never mass-edit or delete content during a suspected restriction without noting what you changed.
- Never rely on the appeal alone; keep your own originals and logs (see playbook).

## 5. How to recover (playbook)

Sourced steps are marked; the rest is my judgement.

1. **Diagnose which kind of penalty.** On Instagram open Account Status and read the stated reason (P, Instagram blog). Compare follower versus non-follower reach in Insights (vendor heuristic, **U**). On X, a suspension shows at login; a reach or monetisation loss produces no notice (**U**, from search snippet).
2. **If originality-related (Instagram):** remove or stop posting aggregated posts and publish original or substantially transformed work for 30 days; eligibility is recalculated on an ongoing basis (P, Instagram blog). Appeal via Account Status if you think it was mistaken.
3. **Appeal once, concisely, with evidence of originality** (source files, project files, timestamps). Expect weak outcomes: 72% of surveyed creators said the appeal did not help (C8). Do not spam appeals.
4. **If wrongly suspended during a platform event** (C13): check whether X acknowledged a bug; Bier said about 99% of March victims were restored. Wait, then appeal.
5. **On X Rewards:** an appeal is allowed once; if it fails you can reapply after 90 days (International Finance, fetched).
6. **Escalate only through legitimate routes** (Meta Verified support, FTC/regulator complaint, press). The Rodney case was reversed after press involvement (C6), but this is one anecdote.
7. **Remove at-risk content:** delete the solicitations or flagged posts before appealing; tighten automation to zero.
8. **Hedge:** keep a mailing list or cross-link between the two accounts so a ban does not zero the project. The Hanson case (C5) shows a nearly 1M-follower business lost with no review.

## 6. Implications for us

- **Our biggest Instagram risk is not anonymity or AI, it is originality.** Alpine facts/mood pages built on stock, scraped or reposted footage would sit squarely in C1. Reels-first with AI-generated or self-made footage and own text overlays should qualify, but "substantial share original over 30 days" is undefined, so keep a clear majority of posts materially our own.
- **Label policy:** our pages show no AI-generated person, so the C3 label should not apply; but if we ever use an AI mascot or narrator face, label the profile. For AI scenery, expect possible auto-labels (C4); disclosure is cheap.
- **X Stoic page:** quote pages are exposed on two fronts: originality (quotes are public domain but "thin summary" and aggregation are excluded from rewards) and automation. Compose posts by hand or with AI as a drafting aid only; do not run auto-reply or auto-engagement. Scheduling through the official API appears acceptable but I found only vendor assertions, and X's own text was not fetched.
- **No monetisation reliance before checking OCR eligibility** (500 verified followers, 500,000 qualifying impressions per the International Finance summary; thresholds conflict across outlets).
- **Operational safety:** one human-operated device, no linked-account boosting, no engagement bait, keep source files and dated logs for appeals.
- **Open question for the next research pass:** documented outcomes of faceless/stock-footage Reel pages after April 2026, and Reddit first-hand reports on Instagram appeals after the originality rule. Neither was retrievable.

## 7. Sources

Fetched this session:
- Instagram Creators blog, "Rewarding original creators on Instagram" (2026-04-30): https://creators.instagram.com/blog/rewarding-original-creators-on-instagram (P)
- TechCrunch (2026-04-30): https://techcrunch.com/2026/04/30/instagram-restricts-reach-of-content-aggregators-in-new-crackdown/ (S)
- MobileSyrup (2026-05-01): https://mobilesyrup.com/2026/05/01/instagram-tweaks-algorithm-to-reduce-reach-of-content-aggregators/ (S)
- Engadget on AI-generated profile label (2026-08-31): https://engadget.com/2246914/instagram-will-demote-ai-generated-influencers-if-they-dont-clearly-label-their-account/ (S)
- Influencer Marketing Hub on Meta unoriginal content: https://influencermarketinghub.com/facebook-push-against-unoriginal-content/ (S)
- The Next Web, Meta AI bans (2026-07-22): https://thenextweb.com/news/meta-ai-moderation-account-bans (S)
- The Star (2026-07-26): https://www.thestar.com.my/tech/tech-news/2026/07/26/what-happened-when-meta-used-ai-to-ban-accounts-on-facebook-and-instagram (S)
- LSE news on Are's study (2026-02-26): https://www.lse.ac.uk/news/latest-news-from-lse/instagrams-account-status-tools-criticised-as-opaque-ineffective-and-discriminatory-by-creators-in-new-study (P, peer-reviewed summary). Paper DOI 10.1177/29768624261426793, https://researchonline.lse.ac.uk/id/eprint/137128 (PDF unreadable)
- Digg, Bier post on ~4,000 removals (2026-07-16): https://digg.com/ai/7u90oynb (S)
- Innovation Village (2026-07-20): https://innovation-village.com/x-removes-4000-creators-over-stolen-content/ (S)
- Startup Fortune (2026-07-25): https://startupfortune.com/x-removes-42000-ai-reply-bot-accounts-and-the-warning-to-growth-marketers-is-impossible-to-ignore/ (S)
- PiunikaWeb (2026-05-28): https://piunikaweb.com/2026/05/28/x-suspend-accounts-ai-replies/ (S/U)
- PiunikaWeb (2026-03-14): https://piunikaweb.com/2026/03/14/x-users-report-wave-of-bans-for-inauthentic-behaviors/ (S)
- roboin.io (2026-04-05): https://roboin.io/article/en/2026/04/05/mass-account-suspensions-on-x-in-april-2026-timeline-and-root-causes-explained/ (S/U)
- Tech-ish (2026-03-26): https://tech-ish.com/2026/03/26/nigeria-south-africa-x-twitter-reply-spam (S)
- The Block (2026-01): https://www.theblock.co/post/385847/ (S)
- Decrypt on X v. Sen and Sherpa (2026-09): https://decrypt.co/378877/x-sues-bitcoin-influencers-bot-army-creator-payout (S)
- eWEEK (2026-03-05): https://www.eweek.com/news/x-suspends-creators-unlabeled-ai-war-videos/ (S)
- International Finance on Original Content Rewards: https://internationalfinance.com/technology/x-kills-revenue-sharing-to-start-paying-only-for-work-you-actually-made/ (S)

Not fetched (flagged, used only where marked U or not at all):
- PetaPixel 2026-04-30 (403): https://petapixel.com/2026/04/30/new-instagram-policies-target-reposted-content/
- PetaPixel 2024-05-28 "Made with AI" (403): https://petapixel.com/2024/05/28/instagram-photos-are-being-labeled-made-with-ai-when-theyre-not/
- Information Democracy shadow-banning report (unreadable PDF): https://informationdemocracy.org/wp-content/uploads/2025/10/The-shadow-banning_English_final.pdf
- help.x.com suspended accounts (403); runtimewire.com Monid AI article (404); Reddit threads (none retrieved); scheduler/follower-buying vendor blogs (search snippets only).
