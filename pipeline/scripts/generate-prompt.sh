#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Generate a Claude Code build prompt from a use-case manifest entry.
# Category-aware page mapping for domain-relevant builds.
# Supports optional --source-data flag for ingested website content.
# ============================================================================

NAME="" TYPE="" REPO="" DESCRIPTION="" FEATURES="" CATEGORY=""
BG="#FFFFFF" PRIMARY="#3B82F6" VIBE="Professional and modern"
SOURCE_DATA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)         NAME="$2"; shift 2 ;;
    --type)         TYPE="$2"; shift 2 ;;
    --repo)         REPO="$2"; shift 2 ;;
    --description)  DESCRIPTION="$2"; shift 2 ;;
    --features)     FEATURES="$2"; shift 2 ;;
    --bg)           BG="$2"; shift 2 ;;
    --primary)      PRIMARY="$2"; shift 2 ;;
    --vibe)         VIBE="$2"; shift 2 ;;
    --category)     CATEGORY="$2"; shift 2 ;;
    --source-data)  SOURCE_DATA="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# If source data exists, inject it as context
SOURCE_BLOCK=""
if [[ -n "$SOURCE_DATA" && -f "$SOURCE_DATA" ]]; then
  SOURCE_BLOCK="
**IMPORTANT — Source Data Available:**
The following real business data was scraped from an existing website. Use this INSTEAD of placeholder/template content wherever it provides real information (business name, services, pricing, team, contact info, testimonials, etc.). Only fall back to template content where the source data has gaps.

\`\`\`json
$(cat "$SOURCE_DATA")
\`\`\`
"
fi

# --- Category-aware page mapping ---
get_pages() {
  local cat="$1"
  case "$cat" in
    "Travel & Booking")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with search bar for destinations. Featured destinations grid. Key stats (routes, partners, happy travelers). Clear CTA.
2. **Search/Explore** (`/search`) — Filterable search results. Sort by price/rating/duration. Map view toggle. Card-based results with thumbnails.
3. **Destinations** (`/destinations`) — Browse destinations by region/type. Each card: location image placeholder, rating, price range, highlights.
4. **Booking** (`/booking`) — Multi-step booking form (dates, travelers, options, payment). Progress indicator. Price breakdown sidebar. Add-ons/extras.
5. **Dashboard** (`/dashboard`) — User dashboard: upcoming trips, past bookings, saved destinations, loyalty points. Sidebar nav.
6. **Pricing/Plans** (`/pricing`) — Membership tiers (Free, Plus, Premium). Feature comparison. Annual/monthly toggle. CTA per tier.
7. **About** (`/about`) — Company story, global partnerships, team, trust badges. How it works (4 steps).
8. **Blog** (`/blog`) — Travel guides, destination spotlights, tips. Card grid with featured post.
9. **FAQ** (`/faq`) — Accordion Q&A: booking, cancellation, payments, loyalty, safety, group travel.
10. **Contact** (`/contact`) — Contact form, support hours, regional offices, emergency travel line.
PAGES
      ;;
    "Financial Services")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with value proposition. Trust indicators (regulated, insured, encrypted). Product highlights. Key financial stats.
2. **Products/Services** (`/services`) — Financial products with detailed breakdowns. Comparison cards. APR/rate displays. Eligibility checkers.
3. **Calculator/Tools** (`/tools`) — Interactive financial calculators (loan, investment, savings, ROI). Input sliders, real-time results, charts.
4. **Application** (`/apply`) — Multi-step application form with progress bar. Document upload section. Eligibility pre-check. Terms acceptance.
5. **Dashboard** (`/dashboard`) — Account overview: balances, transactions, charts, alerts. Portfolio view. Sidebar navigation.
6. **Pricing/Rates** (`/pricing`) — Fee schedules, rate tables, tier comparisons. Transparent pricing breakdown. No-hidden-fees callout.
7. **About** (`/about`) — Company history, leadership team, licenses, security certifications. Trust and compliance section.
8. **Resources** (`/blog`) — Financial literacy articles, market updates, guides. Card grid with categories.
9. **FAQ** (`/faq`) — Accordion Q&A: accounts, transfers, security, fees, regulations, support.
10. **Contact** (`/contact`) — Contact form, branch locator placeholder, phone, secure messaging info.
PAGES
      ;;
    "Healthcare Tech")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with health-focused messaging. Trust badges (HIPAA, certified). Service highlights. Patient testimonials.
2. **Services** (`/services`) — Medical services/specialties. Provider cards. Telemedicine options. Insurance accepted list.
3. **Health Assessment** (`/assessment`) — Interactive symptom checker or health quiz. Step-by-step flow. Risk score output. Recommendation cards.
4. **Patient Portal** (`/portal`) — Appointment booking form. Date/time picker. Provider selection. Insurance info. Confirmation flow.
5. **Dashboard** (`/dashboard`) — Patient dashboard: upcoming appointments, health records summary, prescriptions, messages. Sidebar nav.
6. **Plans/Insurance** (`/pricing`) — Health plans or service packages. Coverage comparison table. Deductible calculator. Enroll CTA.
7. **About** (`/about`) — Practice story, medical team with credentials, certifications, facility info. Patient-first values.
8. **Health Blog** (`/blog`) — Wellness tips, condition guides, research highlights. Card grid with medical categories.
9. **FAQ** (`/faq`) — Accordion Q&A: appointments, insurance, telehealth, prescriptions, privacy, emergencies.
10. **Contact** (`/contact`) — Contact form, office locations, emergency numbers, hours, patient support line.
PAGES
      ;;
    "Green & Sustainability")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with environmental impact stats. Before/after visuals. Carbon savings counter. Green certifications.
2. **Solutions** (`/services`) — Green products/services with environmental impact metrics. Comparison cards showing savings (energy, CO2, water).
3. **Impact Calculator** (`/calculator`) — Interactive calculator: estimate savings (energy, carbon, cost). Input fields for home/business size. Visual results.
4. **Get Started** (`/get-started`) — Multi-step onboarding form. Site assessment request. Quote builder. Financing options.
5. **Dashboard** (`/dashboard`) — Impact dashboard: energy saved, carbon offset, cost savings over time. Charts and progress bars. Sidebar nav.
6. **Pricing** (`/pricing`) — Packages/plans with ROI projections. Financing options. Rebate/incentive info. Payback timeline.
7. **About** (`/about`) — Mission, sustainability certifications, team, environmental partnerships. Impact report highlights.
8. **Blog** (`/blog`) — Sustainability tips, industry news, case studies. Card grid with green categories.
9. **FAQ** (`/faq`) — Accordion Q&A: installation, financing, maintenance, warranties, incentives, environmental impact.
10. **Contact** (`/contact`) — Contact form, service areas, consultation booking, office info.
PAGES
      ;;
    "Media & Publishing")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with content showcase. Audience reach stats. Featured content carousel. Creator testimonials.
2. **Content Library** (`/library`) — Browseable content grid with category filters, search, sort. Cards with thumbnails, titles, metrics.
3. **Creator Studio** (`/studio`) — Content creation/management interface. Upload form, metadata editor, scheduling, preview. Rich text area.
4. **Publish** (`/publish`) — Publishing workflow: draft → review → schedule → publish. Distribution channel selector. Analytics preview.
5. **Dashboard** (`/dashboard`) — Analytics dashboard: views, engagement, subscribers, revenue. Charts, top content list. Sidebar nav.
6. **Plans** (`/pricing`) — Creator/publisher tiers (Free, Pro, Enterprise). Storage, bandwidth, feature comparison. Revenue share details.
7. **About** (`/about`) — Platform story, creator community, partnerships. How it works (create → publish → monetize).
8. **Blog** (`/blog`) — Creator success stories, platform updates, content strategy tips. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: publishing, monetization, copyright, distribution, analytics, support.
10. **Contact** (`/contact`) — Contact form, creator support, partnership inquiries, press.
PAGES
      ;;
    "Logistics & Supply Chain")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with logistics network stats. Shipment volume counters. Service corridor map placeholder. Client logos.
2. **Services** (`/services`) — Service types (FTL, LTL, last-mile, warehousing). Mode cards (air, ocean, ground). Coverage details.
3. **Tracking** (`/tracking`) — Shipment tracker: tracking number input, status timeline visualization, map placeholder, ETA display.
4. **Quote/Ship** (`/quote`) — Freight quote calculator: origin, destination, weight, dimensions, mode. Instant rate comparison. Book shipment form.
5. **Dashboard** (`/dashboard`) — Operations dashboard: active shipments, delivery metrics, alerts, fleet status. Tables and charts. Sidebar nav.
6. **Pricing** (`/pricing`) — Rate structures, volume discounts, service level tiers. Transparent surcharge breakdown. Custom enterprise quote CTA.
7. **About** (`/about`) — Company history, fleet/network, certifications (ISO, C-TPAT), partnerships. Coverage map.
8. **Resources** (`/blog`) — Industry insights, regulatory updates, supply chain guides. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: shipping, customs, claims, tracking, hazmat, insurance.
10. **Contact** (`/contact`) — Contact form, regional offices, dispatch line, emergency freight support.
PAGES
      ;;
    "SaaS & Developer Tools")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with code snippet preview. GitHub stars / user count stats. Feature highlights. Integration logos. CTA to try free.
2. **Features** (`/features`) — Detailed feature breakdown with code examples. Architecture diagram placeholder. Integration list. Performance benchmarks.
3. **Playground/Demo** (`/playground`) — Interactive demo area: code editor with syntax highlighting, sample inputs/outputs, "Try it" button. Live preview panel.
4. **Get Started** (`/get-started`) — Quick-start guide: installation steps, config snippets, first-project walkthrough. Copy-paste code blocks.
5. **Dashboard** (`/dashboard`) — Dev dashboard: API usage charts, project list, team members, billing summary, API keys. Sidebar nav.
6. **Pricing** (`/pricing`) — Developer tiers (Free, Pro, Team, Enterprise). API call limits, feature matrix, usage-based pricing calculator.
7. **About** (`/about`) — Founding story, engineering team, open-source philosophy. Tech stack. Backed by / partners section.
8. **Changelog/Blog** (`/blog`) — Release notes, feature announcements, technical deep-dives. Versioned entries with dates.
9. **FAQ** (`/faq`) — Accordion Q&A: API limits, authentication, SDKs, SLA, data privacy, migration.
10. **Contact** (`/contact`) — Contact form, developer community links, support tiers, status page link.
PAGES
      ;;
    "Social Impact")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with mission statement. Impact counters (lives touched, funds raised, projects). Cause spotlights. Donate CTA.
2. **Programs/Causes** (`/programs`) — Active programs with impact descriptions. Category filters. Progress bars showing goals vs achieved.
3. **Impact Map** (`/impact`) — Interactive impact visualization: region cards, beneficiary stats, before/after stories. Progress charts.
4. **Get Involved** (`/get-involved`) — Donate form, volunteer signup, event calendar. Multiple giving levels. Corporate partnership inquiry.
5. **Dashboard** (`/dashboard`) — Donor/volunteer dashboard: giving history, impact reports, tax receipts, upcoming events. Sidebar nav.
6. **Membership** (`/membership`) — Supporter tiers (Friend, Champion, Guardian). Benefits comparison. Monthly/annual toggle. Recognition levels.
7. **About** (`/about`) — Organization story, leadership, annual report highlights, transparency ratings. Partners and endorsements.
8. **Stories/Blog** (`/blog`) — Impact stories, field updates, event recaps. Card grid with emotional imagery placeholders.
9. **FAQ** (`/faq`) — Accordion Q&A: donating, volunteering, tax receipts, where funds go, partnerships, events.
10. **Contact** (`/contact`) — Contact form, regional offices, media inquiries, partnership proposals.
PAGES
      ;;
    "B2B Enterprise")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with enterprise value prop. Client logos. ROI stats. Industry-specific solutions preview. Demo CTA.
2. **Solutions** (`/solutions`) — Solution suites by use case or industry. Detailed capability cards. Integration ecosystem.
3. **Case Studies** (`/case-studies`) — Customer success stories. Metrics-driven results cards. Industry filter. Testimonial quotes.
4. **Demo/Trial** (`/demo`) — Demo request form with company size, use case, timeline fields. Product tour preview. Calendar embed placeholder.
5. **Dashboard** (`/dashboard`) — Admin console: usage analytics, team management, billing, settings. Data tables, KPI cards. Sidebar nav.
6. **Pricing** (`/pricing`) — Enterprise tiers (Starter, Business, Enterprise). Per-seat or usage pricing. Feature matrix. Custom quote CTA.
7. **About** (`/about`) — Company background, leadership team, investors, certifications (SOC2, GDPR). Press mentions.
8. **Resources** (`/blog`) — Whitepapers, webinar recaps, industry analysis. Content type filter. Gated/ungated toggle.
9. **FAQ** (`/faq`) — Accordion Q&A: implementation, security, compliance, integrations, support SLAs, data migration.
10. **Contact** (`/contact`) — Contact form, sales team, partner program, regional offices, support portal link.
PAGES
      ;;
    "Food Tech")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with appetizing gradient imagery. Order count stats. Featured menu items. Delivery area info. Order CTA.
2. **Menu/Products** (`/menu`) — Full menu with category tabs (appetizers, mains, desserts, drinks). Cards with prices, dietary icons, ratings.
3. **Kitchen/Process** (`/kitchen`) — Behind-the-scenes: preparation process, sourcing story, quality standards. Step-by-step visual flow.
4. **Order** (`/order`) — Interactive order builder: item selection, customization options, cart sidebar, delivery/pickup toggle. Order summary.
5. **Dashboard** (`/dashboard`) — Restaurant/kitchen dashboard: incoming orders, prep status, daily revenue, popular items chart. Sidebar nav.
6. **Pricing/Plans** (`/pricing`) — Subscription meal plans or delivery passes. Weekly/monthly options. Dietary preference packages. Savings calculator.
7. **About** (`/about`) — Chef/founder story, sourcing philosophy, kitchen team, food safety certifications.
8. **Blog** (`/blog`) — Recipes, food trends, nutrition tips, behind-the-scenes. Card grid with food categories.
9. **FAQ** (`/faq`) — Accordion Q&A: ordering, delivery, allergens, dietary options, subscriptions, catering.
10. **Contact** (`/contact`) — Contact form, location/hours, catering inquiries, delivery support.
PAGES
      ;;
    "Education & Kids")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with learning-focused messaging. Student/course count stats. Featured courses. Success stories. Enroll CTA.
2. **Courses/Programs** (`/courses`) — Course catalog with category filters (subject, level, age). Cards with duration, difficulty, rating, price.
3. **Learning Hub** (`/learn`) — Interactive learning preview: lesson viewer, progress tracker, quiz sample. Curriculum overview with modules.
4. **Enroll** (`/enroll`) — Enrollment form: course selection, student info, schedule preferences, payment. Group/family discount options.
5. **Dashboard** (`/dashboard`) — Student/parent dashboard: enrolled courses, progress bars, grades, upcoming sessions, certificates. Sidebar nav.
6. **Plans** (`/pricing`) — Education plans (Individual, Family, Classroom). Course bundles. Scholarship info. Annual savings.
7. **About** (`/about`) — Institution story, teaching philosophy, instructor bios, accreditation. Student outcomes and testimonials.
8. **Blog** (`/blog`) — Learning tips, educational trends, parent resources, student spotlights. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: enrollment, schedules, age requirements, technology needs, refunds, certificates.
10. **Contact** (`/contact`) — Contact form, campus info, admissions office, parent support, virtual tour link.
PAGES
      ;;
    "Sports & Recreation")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with energetic sports imagery placeholder. Member stats. Program highlights. Class schedule preview. Join CTA.
2. **Programs/Activities** (`/programs`) — Activity catalog: classes, leagues, camps, personal training. Cards with schedule, level, capacity.
3. **Facilities** (`/facilities`) — Facility showcase: spaces/courts/fields with descriptions, hours, amenities. Virtual tour placeholder. Equipment list.
4. **Book/Register** (`/register`) — Registration form: program selection, participant info, waiver acceptance. Season/session picker. Family registration.
5. **Dashboard** (`/dashboard`) — Member dashboard: bookings, class schedule, fitness progress, billing. Attendance history. Sidebar nav.
6. **Membership** (`/membership`) — Membership tiers (Basic, Premium, VIP). Access level comparison. Family/corporate rates. Trial offer.
7. **About** (`/about`) — Organization history, coaching staff, achievements/awards, community involvement. Mission and values.
8. **Blog** (`/blog`) — Training tips, event recaps, athlete spotlights, nutrition guides. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: membership, scheduling, cancellations, equipment, age requirements, safety policies.
10. **Contact** (`/contact`) — Contact form, facility address/hours, pro shop, event inquiries.
PAGES
      ;;
    "Real Estate Tech")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with property search bar. Listings count, areas served stats. Featured properties. Market trend preview.
2. **Listings/Properties** (`/listings`) — Property grid with filters (type, beds, price, location). Cards with price, sqft, beds/baths, status badge.
3. **Map Search** (`/map`) — Map-centered view placeholder with property pins. List/map toggle. Draw-to-search area. Nearby amenities.
4. **Inquiry/Apply** (`/apply`) — Property inquiry or rental application form. Pre-qualification calculator. Document upload. Scheduling tour.
5. **Dashboard** (`/dashboard`) — Agent/landlord dashboard: active listings, inquiries, showings, analytics. Pipeline view. Sidebar nav.
6. **Plans** (`/pricing`) — Platform plans (Agent, Broker, Enterprise). Listing limits, lead gen features, MLS integration tiers.
7. **About** (`/about`) — Company story, agent team, market expertise, awards. Neighborhoods served.
8. **Market Blog** (`/blog`) — Market reports, buying/selling guides, neighborhood profiles. Card grid with area tags.
9. **FAQ** (`/faq`) — Accordion Q&A: buying, selling, renting, financing, inspections, closing process.
10. **Contact** (`/contact`) — Contact form, office locations, agent directory, virtual consultation booking.
PAGES
      ;;
    "Fashion & Lifestyle")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with bold fashion gradient. New collection spotlight. Style stats. Trending items. Shop CTA.
2. **Collections/Products** (`/collections`) — Product catalog with category filter (clothing, accessories, seasonal). Cards with price, sizes, color swatches.
3. **Lookbook** (`/lookbook`) — Editorial-style layout: styled outfit sets, seasonal themes. Grid with gradient placeholders. Style descriptions.
4. **Shop/Customize** (`/shop`) — Product detail-style page: size selector, color picker, add-to-cart, customization options. Related items.
5. **Dashboard** (`/dashboard`) — Customer dashboard: orders, wishlist, measurements profile, style preferences, returns. Sidebar nav.
6. **Membership** (`/membership`) — Style club tiers (Classic, Premium, VIP). Early access, personal stylist, exclusive drops. Perks comparison.
7. **About** (`/about`) — Brand story, designer/founder, sustainability commitment, craftsmanship, press features.
8. **Style Blog** (`/blog`) — Trend reports, styling tips, behind-the-scenes, brand collaborations. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: sizing, shipping, returns, care instructions, custom orders, sustainability.
10. **Contact** (`/contact`) — Contact form, showroom/store info, wholesale inquiries, press.
PAGES
      ;;
    "Legal & Compliance")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with professional authority. Case stats/win rates. Practice area highlights. Free consultation CTA.
2. **Practice Areas** (`/services`) — Legal services by specialty. Detailed scope cards with typical outcomes. Attorney assignment.
3. **Resources/Library** (`/resources`) — Legal guides, templates, regulatory updates. Downloadable resources. Category filter.
4. **Consultation** (`/consultation`) — Consultation request form: case type selector, description textarea, preferred contact method, urgency level.
5. **Dashboard** (`/dashboard`) — Client portal: case status timeline, documents, billing, messages, upcoming hearings. Sidebar nav.
6. **Pricing** (`/pricing`) — Fee structures: hourly, flat-fee, contingency. Package comparisons by case type. Payment plans.
7. **About** (`/about`) — Firm history, attorney profiles with credentials/bar admissions, awards, pro-bono commitment.
8. **Blog** (`/blog`) — Legal insights, regulatory changes, case studies, client guides. Card grid with practice area tags.
9. **FAQ** (`/faq`) — Accordion Q&A: initial consultation, fees, case timeline, confidentiality, court process, appeals.
10. **Contact** (`/contact`) — Contact form, office locations, 24/7 hotline, after-hours emergency.
PAGES
      ;;
    "Robotics & Hardware"|"Robot Builder - Home & Business")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with futuristic robot imagery. Robot count/models stats. Featured builds. "Start Building" CTA.
2. **Robot Catalog** (`/catalog`) — Browse robot kits by type (home, industrial, educational, agricultural). Cards with specs, difficulty, price.
3. **Builder/Configurator** (`/builder`) — Interactive robot configurator: select base, sensors, actuators, brain (MCU/SBC). BOM generator, 3D preview placeholder.
4. **Simulator** (`/simulator`) — Robot simulation sandbox: code editor with syntax highlighting, virtual environment preview, sensor readout panels.
5. **Dashboard** (`/dashboard`) — Fleet/project dashboard: active robots, telemetry cards, maintenance schedule, firmware status. Sidebar nav.
6. **Pricing/Kits** (`/pricing`) — Kit tiers (Starter, Pro, Enterprise). Component bundles. Bulk discounts. Subscription for firmware updates.
7. **About** (`/about`) — Company mission, engineering team, R&D lab, partnerships (ROS, Arduino, Raspberry Pi). Open-source commitment.
8. **Docs/Blog** (`/blog`) — Build tutorials, project showcases, firmware changelogs, robotics news. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: assembly, programming, compatibility, warranty, shipping, safety.
10. **Contact** (`/contact`) — Contact form, maker community links, support tiers, Discord/forum link.
PAGES
      ;;
    "AI Wallets & Digital Finance")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with secure vault imagery. AUM/transaction stats. Security certifications. "Connect Wallet" CTA.
2. **Portfolio** (`/portfolio`) — Multi-chain asset overview: token balances, NFT gallery, DeFi positions. Pie chart allocation. Performance graph.
3. **AI Insights** (`/insights`) — AI-powered market analysis: sentiment scores, price predictions, risk alerts. Model confidence indicators.
4. **Swap/Trade** (`/trade`) — Token swap interface: from/to selectors, slippage settings, gas estimator. Transaction history.
5. **Dashboard** (`/dashboard`) — Wallet dashboard: transaction feed, P&L charts, gas spending, staking rewards. Multi-wallet view. Sidebar nav.
6. **Plans** (`/pricing`) — Tiers (Free, Pro, Institutional). AI analysis limits, priority execution, API access. Feature matrix.
7. **About** (`/about`) — Team, security audits, regulatory compliance, insurance coverage. How AI models are trained and validated.
8. **Learn** (`/blog`) — Crypto education, DeFi guides, market recaps, security best practices. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: wallet security, supported chains, fees, KYC, recovery, AI accuracy.
10. **Contact** (`/contact`) — Contact form, security disclosure policy, support channels, status page link.
PAGES
      ;;
    "AI Concierge - Professional Services")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with AI assistant visual. Client satisfaction stats. Service categories. "Get Started" CTA.
2. **Services** (`/services`) — AI concierge offerings by profession (legal, accounting, HR, marketing). Smart matching descriptions.
3. **AI Intake** (`/intake`) — Intelligent client intake form: dynamic questions based on service type, document upload, urgency classifier. AI summary preview.
4. **Matching** (`/matching`) — Professional matching interface: AI-scored provider cards, availability calendar, specialization filters. Compare view.
5. **Dashboard** (`/dashboard`) — Client/firm dashboard: active engagements, AI recommendations, document status, billing summary. Sidebar nav.
6. **Pricing** (`/pricing`) — Service tiers (Pay-per-use, Monthly, Enterprise). AI concierge hours, provider access levels. ROI calculator.
7. **About** (`/about`) — Platform story, AI methodology, professional network size, trust indicators. How matching algorithm works.
8. **Resources** (`/blog`) — Industry insights, AI in professional services, client success stories. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: AI accuracy, data privacy, professional vetting, billing, SLAs, integrations.
10. **Contact** (`/contact`) — Contact form, partnership inquiries, enterprise sales, live chat placeholder.
PAGES
      ;;
    "Technology Professional Services")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with enterprise tech imagery. Client logos, project count stats. Service pillars. Assessment CTA.
2. **Solutions** (`/solutions`) — Service catalog: cloud migration, DevOps, cybersecurity, architecture review. Detailed scope cards.
3. **Assessment** (`/assessment`) — Interactive tech assessment: infrastructure questionnaire, maturity scoring, gap analysis. Recommendation output.
4. **Engagement** (`/engage`) — Engagement request form: project scope, timeline, budget, team size. SOW preview generator.
5. **Dashboard** (`/dashboard`) — Project dashboard: active engagements, milestones, burn rate, deliverables. Resource allocation view. Sidebar nav.
6. **Pricing** (`/pricing`) — Engagement models (T&M, Fixed, Retainer). Rate cards by expertise. Capacity planning tool.
7. **About** (`/about`) — Firm background, consultant profiles, certifications (AWS, Azure, GCP, CISSP). Case studies summary.
8. **Resources** (`/blog`) — Tech insights, whitepapers, architecture patterns, tool comparisons. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: engagement process, NDA, IP ownership, team composition, on-site vs remote.
10. **Contact** (`/contact`) — Contact form, regional offices, RFP submission portal, partner program.
PAGES
      ;;
    "Youth Tech Empowerment")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with vibrant youth imagery. Student count, project stats. Featured programs. "Join Now" CTA. Fun, colorful design.
2. **Programs** (`/programs`) — Course/program catalog: coding, robotics, game dev, AI basics. Age group filters, difficulty badges.
3. **Projects** (`/projects`) — Student project showcase: interactive gallery, category filters, "remix" buttons. Star/like system.
4. **Join/Register** (`/register`) — Registration form: student info, age group, interests, parent contact. Scholarship application option.
5. **Dashboard** (`/dashboard`) — Student dashboard: enrolled programs, badges earned, project portfolio, leaderboard position. Sidebar nav.
6. **Plans** (`/pricing`) — Program pricing (Free tier, Premium, Camp packages). Family discounts. Scholarship fund.
7. **About** (`/about`) — Mission, mentor team, impact stats, partner schools. Success stories and alumni spotlights.
8. **Blog** (`/blog`) — Student spotlights, tech for kids news, project ideas, parent guides. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: age requirements, devices needed, safety, curriculum, certificates, scholarships.
10. **Contact** (`/contact`) — Contact form, school partnership inquiries, volunteer opportunities, parent support.
PAGES
      ;;
    "Web Sandboxing - WASM"|"Web Sandboxing - Bubblewrap"|"Web Sandboxing - OpenShell"|"Web Sandboxing - Cloudflare Workers")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with terminal/code aesthetic. Execution count stats. Technology logos. "Launch Sandbox" CTA. Dark hacker theme.
2. **Playground** (`/playground`) — Interactive sandbox: code editor with syntax highlighting, output panel, file tree. Run/stop buttons. Preset examples.
3. **Templates** (`/templates`) — Pre-built sandbox templates: starter projects, framework boilerplates, tutorial environments. One-click launch.
4. **Environments** (`/environments`) — Environment manager: create, configure, share sandboxes. Resource limits, networking, persistence options.
5. **Dashboard** (`/dashboard`) — User dashboard: active sandboxes, usage metrics, saved sessions, shared environments. Resource graphs. Sidebar nav.
6. **Pricing** (`/pricing`) — Tiers (Free, Developer, Team, Enterprise). Compute limits, storage, concurrent sessions. Usage-based calculator.
7. **About** (`/about`) — Platform architecture, security model, isolation guarantees. Open-source contributions. Technology deep-dive.
8. **Docs/Blog** (`/blog`) — Technical tutorials, use case guides, release notes, benchmark results. Card grid with tags.
9. **FAQ** (`/faq`) — Accordion Q&A: security, supported languages/runtimes, networking, persistence, API access, team collaboration.
10. **Contact** (`/contact`) — Contact form, developer community, GitHub repo link, enterprise sales, status page.
PAGES
      ;;
    "AI Concierge - IT Service Installs")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with AI infrastructure visual. Services deployed count. Supported platforms (OpenClaw, NemoClaw, NanoClaw). "Deploy Now" CTA.
2. **Service Catalog** (`/catalog`) — Browseable catalog of AI services: model types, resource requirements, compatibility matrix. Category filters.
3. **Deploy Wizard** (`/deploy`) — Step-by-step deployment wizard: select service, configure resources (GPU, RAM, storage), set endpoints. Review and launch.
4. **Model Registry** (`/registry`) — Model version browser: model cards, benchmarks, changelog. Compare versions side-by-side. Download/deploy buttons.
5. **Dashboard** (`/dashboard`) — Infrastructure dashboard: running services, GPU utilization, inference latency, cost tracking. Health status. Sidebar nav.
6. **Pricing** (`/pricing`) — Compute tiers by GPU type (T4, A10G, A100, H100). Per-hour and reserved pricing. Spot instance discounts.
7. **About** (`/about`) — Platform capabilities, supported frameworks, security/compliance, partnership with AI labs.
8. **Docs/Blog** (`/blog`) — Deployment guides, model benchmarks, best practices, platform updates. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: GPU availability, model compatibility, scaling, monitoring, data privacy, SLAs.
10. **Contact** (`/contact`) — Contact form, enterprise support, architecture review request, community Slack link.
PAGES
      ;;
    "AI Blogging & Content Platform")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with community/writing visual. Post count, author stats. Trending articles carousel. "Start Writing" CTA.
2. **Feed** (`/feed`) — Content feed: article cards with author, tags, reactions, reading time. Category/tag filters. Trending/latest/top tabs.
3. **Editor** (`/editor`) — Rich text editor: markdown support, AI writing assistant panel, source citation inserter. Preview toggle. Model selector for AI assist.
4. **Article** (`/article`) — Article view template: rendered markdown, author bio, reactions, comment section. Related articles. Source references sidebar.
5. **Dashboard** (`/dashboard`) — Author dashboard: published posts, draft manager, analytics (views, reactions, bookmarks), follower count. Sidebar nav.
6. **Evals** (`/evals`) — Content eval dashboard: AI model used per article, quality scores, readability metrics, source verification status.
7. **About** (`/about`) — Platform mission, content guidelines, AI transparency policy. How AI assists vs generates. Community stats.
8. **Tags/Topics** (`/topics`) — Topic browser: tag cloud, category pages, top authors per topic. Follow topics.
9. **FAQ** (`/faq`) — Accordion Q&A: AI content policy, attribution, monetization, moderation, API access, data export.
10. **Contact** (`/contact`) — Contact form, content partnerships, advertising, moderation appeals, API inquiries.
PAGES
      ;;
    "Markdown Website Builder")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with minimal design aesthetic. Sites built count. "Create from Markdown" CTA. Live preview animation.
2. **Builder** (`/builder`) — Split-pane editor: markdown input (left), live rendered preview (right). Theme selector, component inserter.
3. **Templates** (`/templates`) — Site templates: portfolio, docs, blog, landing, dashboard. Preview and one-click fork. Markdown source included.
4. **AGUI Dashboard** (`/agui`) — AI-generated UI builder: describe dashboard in natural language, auto-generate layout. Drag-to-adjust. Export markdown.
5. **Dashboard** (`/dashboard`) — User dashboard: my sites, deploy status, analytics, custom domains. SSO configuration (GitHub, Google). Sidebar nav.
6. **Pricing** (`/pricing`) — Tiers (Free, Pro, Team). Sites limit, custom domains, AGUI generation credits. SSO provider options.
7. **About** (`/about`) — Platform philosophy (markdown-first), technology stack, open-source components. Developer story.
8. **Docs/Blog** (`/blog`) — Markdown tips, theming guides, AGUI tutorials, showcase sites. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: markdown syntax, custom domains, SSO setup, AGUI limits, export options, self-hosting.
10. **Contact** (`/contact`) — Contact form, GitHub repo, developer community, feature requests, enterprise licensing.
PAGES
      ;;
    "AI Services Management")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with multi-service dashboard preview. Businesses managed count. Platform logos (Paperclip, n8n, Dify). "Get Started" CTA.
2. **Services** (`/services`) — Service catalog: Paperclip-as-a-Service, n8n-as-a-Service, Dify-as-a-Service. Feature cards, deployment options.
3. **Provisioner** (`/provision`) — Service provisioner: select service, configure tier, assign to business, set resource limits. One-click deploy.
4. **Multi-Business** (`/businesses`) — Business switcher: list of managed businesses, service status per business, usage/cost breakdown. Add new business flow.
5. **Dashboard** (`/dashboard`) — Unified dashboard: all services across all businesses, health status, cost aggregation, alert feed. Sidebar nav with business switcher.
6. **Pricing** (`/pricing`) — Per-service pricing: compute, storage, API calls. Bundle discounts for multi-service. Enterprise custom.
7. **About** (`/about`) — Platform vision (unified AI management), team, security posture, uptime SLA. Integration partners.
8. **Docs/Blog** (`/blog`) — Platform guides, workflow recipes, case studies, release notes. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: multi-tenancy, data isolation, scaling, migrations, backup, API access.
10. **Contact** (`/contact`) — Contact form, enterprise sales, partner program, support tiers, status page.
PAGES
      ;;
    *)
      # Default/generic/Misc Services/Niche
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero section with compelling headline. Key stats/social proof. Service/product highlights. Clear CTA.
2. **Services/Products** (`/services`) — Detailed offerings with descriptions and pricing. Package/tier cards. Comparison table.
3. **Gallery/Portfolio** (`/gallery`) — Visual showcase of work/products. Category filters. Grid layout with gradient placeholders.
4. **Booking/Order** (`/booking`) — Interactive form for the primary conversion action. Multi-step if complex. Price calculator.
5. **Dashboard** (`/dashboard`) — Admin/management view. Stats cards, activity table, charts. Sidebar navigation.
6. **Pricing** (`/pricing`) — Tiered pricing (3 levels). Feature comparison table. CTA per tier.
7. **About** (`/about`) — Company story, team, values, certifications. Build trust and credibility.
8. **Blog** (`/blog`) — Industry tips, company news, guides. Card grid with categories.
9. **FAQ** (`/faq`) — Accordion-style Q&A. 5-6 sections covering common questions for this business type.
10. **Contact** (`/contact`) — Contact form, phone, email, address, hours, map placeholder.
PAGES
      ;;
  esac
}

PAGES_BLOCK=$(get_pages "$CATEGORY")

cat << PROMPT
Build a complete ${NAME} web application and push it to GitHub.

**Project Details:**
- Name: ${NAME}
- Type: ${TYPE} — ${DESCRIPTION}
- Category: ${CATEGORY}
- Repo: devopseng99/${REPO} (already created, empty)
- Stack: Next.js 14+ with App Router, TypeScript, Tailwind CSS, static export for Cloudflare Pages

**CRITICAL BUILD RULES:**
- Any page with useState, onClick, onChange, onSubmit, or any event handlers MUST have \`'use client';\` as the very first line
- Set \`output: 'export'\` and \`images: { unoptimized: true }\` in next.config
- Test with \`npm run build\` before pushing — it MUST succeed. If it fails, fix and retry.
${SOURCE_BLOCK}

**Key Features to incorporate:** ${FEATURES}

**Pages to build (10 pages):**

${PAGES_BLOCK}

**Design:**
- Background: ${BG}
- Primary accent: ${PRIMARY}
- Vibe: ${VIBE}
- Responsive with mobile hamburger menu
- Shared header/footer layout
- Use gradient placeholders for all images (no external image URLs)

**Steps:**
1. Clone: \`export GH_TOKEN=\$(kubectl get secret github-credentials -n paperclip -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d) && git clone https://\${GH_TOKEN}@github.com/devopseng99/${REPO}.git /tmp/${REPO}\`
2. Initialize Next.js, build all 10 pages
3. \`npm run build\` must succeed
4. Git commit and push to main
PROMPT
