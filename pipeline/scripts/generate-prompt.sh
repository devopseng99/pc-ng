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
    "Next-Gen UI Platform")
      cat << 'PAGES'
1. **Landing page** (`/`) — Full-viewport video hero (autoplay muted loop with poster frame fallback). Overlay text with parallax on scroll. Animated gradient mesh background behind content. Scroll-triggered reveal animations for feature sections. Marquee ticker of client logos. CTA with animated gradient border.
2. **Features** (`/features`) — Bento grid layout with asymmetric cards (2x1, 1x1, 2x2). Each card has hover 3D tilt effect (perspective transform). Spotlight cursor-following radial gradient on card borders. Staggered scroll-reveal animations. Interactive code/demo snippets in feature cards.
3. **Product/Demo** (`/demo`) — Split-screen layout: left side sticky with 3D product viewer or animated illustration, right side scrolls through feature descriptions. Content on left morphs/transitions as user scrolls through sections. Progress indicator on the side.
4. **Playground** (`/playground`) — Terminal/code aesthetic page with monospace fonts. Interactive code editor with syntax highlighting (Shiki). Typing animation on example code. Dark theme with green/amber terminal colors. Live preview panel with glassmorphism styling.
5. **Dashboard** (`/dashboard`) — Dark mode dashboard with animated counters that count up on scroll-reveal. Data visualization cards with SVG chart animations. Glassmorphism sidebar nav. Gradient mesh accent backgrounds. Command palette (Cmd+K) overlay. Animated progress rings.
6. **Pricing** (`/pricing`) — Cards with animated gradient borders (spinning conic gradient). Hover spotlight effect. Comparison table with reveal-on-scroll rows. Toggle animation between monthly/annual. Floating particle/constellation background.
7. **About** (`/about`) — Storytelling scroll page (Apple-style). Full-viewport sections scrubbed by scroll position. Team cards with 3D hover tilt. Timeline with morphing SVG blob connectors. Animated counter stats (customers, uptime, etc).
8. **Gallery/Showcase** (`/showcase`) — Horizontal scroll gallery section (vertical scroll maps to horizontal movement). Masonry grid for projects. Cards scale up when centered. Image reveal with clip-path animation. Category filter with layout animation.
9. **Blog** (`/blog`) — Card grid with reveal-on-scroll. Featured post with glassmorphism overlay on gradient background. Reading time estimates. Tag pills with hover animation. Infinite scroll with skeleton loaders.
10. **Contact** (`/contact`) — Neumorphic form elements (soft shadow inputs). Morphing blob decorative background. Form validation with micro-animations. Success state with confetti/particle burst. macOS dock-style social links at bottom.
PAGES
      ;;
    "WASM & Sandbox Runtimes")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with animated WASM logo/visualization. Runtime stats (modules deployed, namespaces active, execution count). Feature highlights with architecture diagram placeholder. "Launch Sandbox" CTA.
2. **Sandbox/Playground** (`/sandbox`) — Interactive sandbox environment: code editor with syntax highlighting, runtime selector (WASM/Container/gVisor), execute button, output panel with metrics (cold start, memory, CPU). Real-time streaming output.
3. **Namespaces** (`/namespaces`) — Namespace management dashboard: create/delete namespaces, resource quota displays (CPU, memory, storage), RBAC role assignment, namespace health status indicators. List view with status badges.
4. **Deployments** (`/deployments`) — Deploy manager: upload WASM modules or container images, configure environment variables, set resource limits, select runtime class. Deployment history table with rollback buttons.
5. **Dashboard** (`/dashboard`) — Operations dashboard: active workloads, resource utilization charts (CPU/memory/network), namespace breakdown, recent events feed, health alerts. Sidebar nav with namespace switcher.
6. **Pricing** (`/pricing`) — Tiers (Free Sandbox, Pro, Enterprise). Execution minutes, namespace count, storage, concurrent deployments. Usage calculator. Resource limit comparison matrix.
7. **About** (`/about`) — Platform architecture explanation, supported runtimes (WASM, gVisor, Kata), security model, team. Open-source components and contribution guide.
8. **Docs/Blog** (`/blog`) — Technical guides: WASM getting started, runtime comparison, K8s integration patterns, security best practices. Card grid with difficulty levels.
9. **FAQ** (`/faq`) — Accordion Q&A: WASM vs containers, supported languages, namespace limits, security isolation, billing, API access, data persistence, networking.
10. **Contact** (`/contact`) — Contact form, developer community links (Discord/Slack), enterprise sales, API status page, GitHub repo link.
PAGES
      ;;
    "AI Image Generation"|"AI Video Generation"|"AI Audio & Voice")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with AI-generated sample gallery carousel. "Generate Now" CTA. Stats (images created, users). Pricing teaser. Trust badges (API providers).
2. **Generate** (`/generate`) — Main generation UI: prompt input (textarea with examples), model/style selector, aspect ratio picker, quality settings. Generate button with progress indicator. Result gallery with download/share buttons.
3. **Gallery** (`/gallery`) — Community/public gallery of generated content. Filter by style, model, trending. Like/save. Click to see prompt used. Infinite scroll.
4. **Pricing** (`/pricing`) — Credit packs or subscription tiers. Free tier (5/day), Pro ($9.99/mo), Agency ($49.99/mo). Usage calculator. Feature comparison table.
5. **Dashboard** (`/dashboard`) — User dashboard: generation history, credits remaining, usage charts, saved favorites, billing info. Sidebar nav.
6. **API Docs** (`/api`) — API documentation: endpoints, auth (API key), request/response examples, rate limits, SDKs. Interactive playground.
7. **About** (`/about`) — Platform story, AI model info (what models power it), ethical usage policy, team.
8. **Blog** (`/blog`) — Tutorials (prompt engineering tips, use cases, workflow guides), product updates, case studies. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: pricing, commercial usage rights, API limits, refund policy, supported formats, NSFW policy.
10. **Contact** (`/contact`) — Contact form, enterprise inquiries, API partnership, support email, Discord/community link.
PAGES
      ;;
    "AI Chat & Agents")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with chat demo animation. "Try Free" CTA. Agent showcase cards. Stats (conversations, agents deployed). Integration logos.
2. **Chat** (`/chat`) — Main chat interface: conversation list sidebar, message thread with markdown rendering, model selector, system prompt editor. Streaming responses.
3. **Agents** (`/agents`) — Agent marketplace/builder: browse templates, create custom agent, configure tools/knowledge, test in sandbox. Agent cards with ratings.
4. **Pricing** (`/pricing`) — Freemium tiers: Free (100 msgs/day), Pro ($19/mo unlimited), Team ($49/mo + collaboration). Feature matrix.
5. **Dashboard** (`/dashboard`) — Usage analytics: messages sent, tokens used, cost breakdown, conversation history, agent performance metrics. Sidebar nav.
6. **API** (`/api`) — API documentation: chat completions endpoint, agent deployment API, webhook integrations, authentication. Code samples in Python/JS/curl.
7. **About** (`/about`) — Platform overview, AI models used, security & privacy policy, team.
8. **Blog** (`/blog`) — Agent building tutorials, prompt engineering, workflow automation guides, customer stories. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: data privacy, model selection, rate limits, enterprise features, custom training.
10. **Contact** (`/contact`) — Contact form, enterprise sales, partner program, support, community links.
PAGES
      ;;
    "AI Productivity")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with product demo screenshot/animation. "Start Free" CTA. Feature highlights with icons. Social proof (users, companies). Integration logos.
2. **App** (`/app`) — Main application workspace: file upload/input area, AI processing status, results panel with actions (download, share, copy). Clean functional layout.
3. **Templates** (`/templates`) — Pre-built templates/presets for common workflows. Category filters. Preview + one-click use. User-submitted templates.
4. **Pricing** (`/pricing`) — Freemium: Free (limited), Pro ($12/mo), Business ($39/mo). Feature comparison. Annual discount.
5. **Dashboard** (`/dashboard`) — User dashboard: recent activity, usage stats, saved outputs, team management (if applicable), billing. Sidebar nav.
6. **Integrations** (`/integrations`) — Available integrations: Google Workspace, Slack, Notion, Zapier. Setup guides per integration.
7. **About** (`/about`) — Product story, how it works (3-step diagram), team, press mentions.
8. **Blog** (`/blog`) — Productivity tips, workflow guides, feature announcements, case studies. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: data security, export formats, team features, API access, supported file types.
10. **Contact** (`/contact`) — Contact form, support email, enterprise inquiries, feature requests, status page.
PAGES
      ;;
    "API Infrastructure")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with API request/response animation. "Get API Key" CTA. Supported models/services. Latency stats. Code snippet preview.
2. **Playground** (`/playground`) — Interactive API playground: model selector, input editor, parameter tuning (temp, max tokens), execute button, response viewer with timing metrics.
3. **Documentation** (`/docs`) — Full API reference: authentication, endpoints, request/response schemas, error codes, rate limits. Language tabs (Python, JS, curl, Go).
4. **Pricing** (`/pricing`) — Pay-as-you-go with volume discounts. Model-specific pricing table. Free tier (1K requests/mo). Calculator.
5. **Dashboard** (`/dashboard`) — Developer dashboard: API keys management, usage charts (requests, tokens, cost), error rate, latency percentiles. Sidebar nav.
6. **SDKs** (`/sdks`) — Official SDKs: npm, pip, go packages. Quick start guides. GitHub links with star counts.
7. **About** (`/about`) — Platform architecture, infrastructure (edge, caching), uptime SLA, team, investors.
8. **Blog** (`/blog`) — Technical deep-dives, model benchmarks, integration tutorials, changelog. Card grid.
9. **Status** (`/status`) — Real-time API status: uptime %, latency charts, incident history, subscribe to alerts.
10. **Contact** (`/contact`) — Contact form, enterprise sales, SLA inquiries, support tiers, Discord developer community.
PAGES
      ;;
    "CF Dynamic Sandboxes"|"CF Containers"|"CF Agents SDK")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with live sandbox/container demo animation (terminal typing effect). Stats (sandboxes spawned, uptime, global locations). Architecture diagram. "Launch Sandbox" CTA.
2. **Playground** (`/playground`) — Interactive sandbox: code editor (Monaco) with language selector, execute button, real-time output panel with metrics (cold start ms, memory MB, CPU time). Share button for results.
3. **Dashboard** (`/dashboard`) — User dashboard: active sandboxes/agents, execution history table, resource usage charts (CPU, memory, invocations), cost breakdown. Sidebar nav with project switcher.
4. **API Docs** (`/docs`) — API reference: REST endpoints, SDK examples (JS/Python), authentication, rate limits, webhook configuration. Interactive "Try it" panels.
5. **Pricing** (`/pricing`) — Usage-based tiers: Free (1K executions/day), Pro ($19/mo, 100K), Enterprise (custom). Feature comparison. Cost calculator.
6. **Templates** (`/templates`) — Pre-built sandbox templates: web scraper, data processor, AI agent, API tester, CI runner. One-click deploy. Community submissions.
7. **About** (`/about`) — Platform architecture (V8 isolates, container runtime), security model (isolation guarantees), team, compliance.
8. **Blog** (`/blog`) — Technical guides: sandbox patterns, agent architectures, performance optimization, security best practices. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: execution limits, supported languages, networking, file system access, cold start times, data persistence.
10. **Contact** (`/contact`) — Contact form, enterprise sales, security inquiries, community Discord, GitHub.
PAGES
      ;;
    "CF Queues & Workflows"|"CF Durable Objects")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with animated workflow/pipeline visualization (nodes connecting). Stats (jobs processed, uptime, avg latency). "Start Building" CTA.
2. **Builder** (`/builder`) — Visual workflow/pipeline editor: drag-and-drop nodes (trigger, transform, branch, AI, output), connect with edges, configure each step. Test run with sample data.
3. **Dashboard** (`/dashboard`) — Operations dashboard: active workflows, execution timeline, success/failure rates, queue depth charts, dead-letter queue alerts. Sidebar nav.
4. **Monitoring** (`/monitoring`) — Real-time monitoring: live execution trace viewer, step-by-step progress, retry counts, latency per step. WebSocket-powered live updates.
5. **Pricing** (`/pricing`) — Usage tiers: Free (10K events/day), Pro ($29/mo), Enterprise. Per-execution and per-step pricing. Volume discounts.
6. **Templates** (`/templates`) — Pre-built workflow templates: webhook router, ETL pipeline, AI batch processor, alert escalation. One-click clone + customize.
7. **About** (`/about`) — Architecture overview (Queues, Workflows, Durable Objects), reliability guarantees (at-least-once delivery), team.
8. **Blog** (`/blog`) — Workflow patterns, event-driven architecture guides, case studies, performance tuning. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: message retention, retry policies, ordering guarantees, batch sizes, dead-letter handling, monitoring.
10. **Contact** (`/contact`) — Contact form, enterprise sales, integration help, community, status page.
PAGES
      ;;
    "CF Workers AI"|"CF AI Search"|"CF AI Gateway"|"CF Vectorize")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with AI model demo (live inference preview). Stats (inferences/day, models available, global edge locations). Model showcase cards. "Try Free" CTA.
2. **Playground** (`/playground`) — AI playground: model selector, input area (text/image/audio), parameter controls, generate button, output panel with latency + token metrics. Compare models side-by-side.
3. **Dashboard** (`/dashboard`) — Usage dashboard: inference count, token usage, cost per model, cache hit rate (AI Gateway), vector index stats (Vectorize). Sidebar nav.
4. **Models** (`/models`) — Model catalog: text generation, image generation, embeddings, speech. Cards with benchmarks, pricing, example outputs. Filter by task type.
5. **Pricing** (`/pricing`) — Model-specific pricing table. Free tier (10K neurons/day). Pay-per-use. Cost calculator. Caching savings estimator.
6. **API Docs** (`/docs`) — API reference: inference endpoints, model parameters, streaming responses, batch API, webhooks. Code samples in JS/Python/curl.
7. **About** (`/about`) — Platform (Workers AI infrastructure, AI Gateway routing, Vectorize architecture), privacy/security, team.
8. **Blog** (`/blog`) — Model comparisons, RAG tutorials, prompt engineering, fine-tuning guides, benchmarks. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: model availability, latency, rate limits, data privacy, custom models, fine-tuning, caching behavior.
10. **Contact** (`/contact`) — Contact form, enterprise API plans, model requests, community, Discord.
PAGES
      ;;
    "CF Browser Rendering"|"CF D1 Database"|"CF R2 Storage"|"CF Hyperdrive"|"CF Realtime")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with product demo (screenshot of main feature in action). Stats (requests processed, data stored, global reach). Feature highlights. "Get Started Free" CTA.
2. **App** (`/app`) — Main application interface: primary tool/editor area, configuration panel, results/output section. Clean functional layout optimized for the core workflow.
3. **Dashboard** (`/dashboard`) — Usage dashboard: request counts, storage used, bandwidth, latency charts, error rates. Resource management (create/delete). Sidebar nav.
4. **Pricing** (`/pricing`) — Free tier with generous limits. Pro ($12/mo) with higher limits. Enterprise custom. Usage calculator. Feature comparison.
5. **API Docs** (`/docs`) — REST API reference: endpoints, auth, request/response schemas, pagination, error codes. SDK quickstart guides (JS, Python).
6. **Integrations** (`/integrations`) — Integration guides: connect with Workers, Pages, external services. Webhook setup. Third-party tool connectors.
7. **About** (`/about`) — Platform architecture, performance benchmarks, security model, team.
8. **Blog** (`/blog`) — How-to guides, architecture patterns, migration guides, performance tips. Card grid.
9. **FAQ** (`/faq`) — Accordion Q&A: limits, data residency, backup/restore, migration, API compatibility, pricing details.
10. **Contact** (`/contact`) — Contact form, enterprise inquiries, support tiers, community, status page.
PAGES
      ;;
    "MCP Live Baseball"|"MCP Live Football"|"MCP Live Basketball"|"MCP Live Soccer")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with live game preview card showing real-time score. "Live Now" indicator with pulsing dot. Sport-specific field/court/diamond SVG. Stats counter (games tracked, feeds connected). "Watch Live" CTA.
2. **Live Feed** (`/live`) — Main real-time dashboard: active game cards with SSE live scores, play-by-play event stream, animated field/court position diagram (SVG canvas). Auto-refreshing stat overlays. Game selector sidebar.
3. **Scoreboard** (`/scores`) — Multi-game grid: all active and recent games in card layout. Score, period/inning/quarter, time remaining. Click to expand with box score. Filterable by date and team.
4. **Stats** (`/stats`) — Player and team statistics: leaderboards, comparison tool, stat category filters. Charts (bar, radar, line) for performance trends. Search by player name.
5. **Schedule** (`/schedule`) — Upcoming games calendar grid. Countdown timers. TV/streaming info. Timezone selector. Add to calendar export.
6. **Standings** (`/standings`) — League/division standings table with record, streak, last 10, GB. Playoff picture bracket. Sortable columns.
7. **MCP Feeds** (`/feeds`) — Connected MCP data source status: API health indicators, last sync time, data freshness gauges. Feed configuration panel.
8. **About** (`/about`) — Platform overview, MCP architecture diagram, data sources, update frequency, team.
9. **FAQ** (`/faq`) — Accordion Q&A: data delay, supported leagues, MCP connectors, API access, mobile support.
10. **Contact** (`/contact`) — Contact form, feature requests, API partnership inquiries, community Discord.
PAGES
      ;;
    "MCP Live UFC"|"MCP Live MMA"|"MCP Live Boxing")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with fight card preview, main event tale-of-the-tape overlay. "Fight Night Live" banner with countdown to next event. Strike stat counters. "Track Fights" CTA.
2. **Live Fight** (`/live`) — Fight night tracker: round-by-round scorecard, strike accuracy heatmap on body diagram SVG, significant strike differential bar chart, takedown/control time gauges. SSE live round events.
3. **Fight Card** (`/card`) — Full event card: each bout as comparison card (fighter photos as gradient placeholders, records, reach, style). Odds display. Result cards for completed bouts.
4. **Rankings** (`/rankings`) — Division/weight class rankings: ranked fighter cards, recent results, title holder spotlight. Cross-promotion comparison toggle.
5. **Fighter Stats** (`/fighters`) — Fighter search and profile: record, finish rate pie chart, striking/grappling radar chart, win method breakdown, fight history timeline.
6. **Schedule** (`/schedule`) — Upcoming events calendar: event name, venue, main card, prelims. Countdown timers. PPV/broadcast info.
7. **Analytics** (`/analytics`) — Advanced fight analytics: strike volume trends, finish probability model, style matchup matrix, historical performance by round.
8. **MCP Feeds** (`/feeds`) — MCP connector status: UFC Stats API, sportsbook odds feed, social sentiment feed. Health checks and sync status.
9. **FAQ** (`/faq`) — Accordion Q&A: scoring methodology, data sources, supported promotions, API access.
10. **Contact** (`/contact`) — Contact form, feature requests, partnership, community.
PAGES
      ;;
    "MCP Multi-Sport"|"MCP Sports Analytics")
      cat << 'PAGES'
1. **Landing page** (`/`) — Hero with multi-sport ticker preview showing live scores across sports. Sport icon grid (baseball, football, basketball, soccer, UFC, boxing). Connected feeds counter. "Explore Feeds" CTA.
2. **Dashboard** (`/dashboard`) — Unified multi-sport dashboard: sport-tabbed sections, active game cards per sport, configurable widget grid (drag-and-drop). Personal favorites pinned at top. SSE live updates.
3. **Live Scores** (`/scores`) — All-sport scoreboard: filterable by sport, league, date. Sport-specific score cards (diamond, field, court, octagon icons). Status badges (live, final, upcoming).
4. **Analytics** (`/analytics`) — Cross-sport analytics tools: player comparison, team trends, odds tracker, prop analyzer. Chart builder with data source selector. Export as image/CSV.
5. **Feeds Manager** (`/feeds`) — MCP connector marketplace: browse available sport feeds, connection status, data freshness, rate limits. Add/remove feed sources. Health monitoring.
6. **Favorites** (`/favorites`) — Personal watchlist: followed teams/players across sports, custom alert rules, notification preferences. Quick-glance status cards.
7. **Calendar** (`/calendar`) — Unified sports calendar: all followed games/events. Conflict detection overlay. Timezone support. iCal sync.
8. **Pricing** (`/pricing`) — Free tier (3 sports, delayed). Pro ($8/mo, all sports, real-time). API access tier. Feature comparison.
9. **FAQ** (`/faq`) — Accordion Q&A: supported sports, data delay, MCP architecture, customization, mobile, API.
10. **Contact** (`/contact`) — Contact form, API partnerships, feature requests, community, status page.
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

# --- Category-specific stack and build rules ---
get_stack_block() {
  case "$1" in
    "Next-Gen UI Platform")
      cat << 'STACKEOF'
- Stack: Astro 4+ with React islands, TypeScript, Tailwind CSS v4, Vite
- UI Libraries: shadcn/ui (Radix-based), Framer Motion for animations
- Structure: Turborepo mono-repo with pnpm workspaces:
  ```
  /
  ├── apps/
  │   └── web/              # Main Astro app
  ├── packages/
  │   ├── ui/               # Shared components (shadcn/ui customized)
  │   ├── config-tailwind/  # Shared Tailwind config + theme tokens
  │   └── utils/            # Shared utilities
  ├── turbo.json
  ├── pnpm-workspace.yaml
  └── package.json
  ```

**CRITICAL BUILD RULES:**
- Initialize with `pnpm create turbo@latest` or set up manually with pnpm workspaces
- Main app is in `apps/web/` — use `npm create astro@latest` with TypeScript + Tailwind
- Add `@astrojs/react` integration for interactive islands
- Add `framer-motion` for scroll animations and page transitions
- Add Astro View Transitions (`<ViewTransitions />` in layout)
- Use `<video autoplay muted loop playsinline poster="/hero-poster.webp">` for video heroes — include a CSS gradient as the poster/fallback, NOT an external URL
- For scroll animations: use Framer Motion `whileInView` + `variants` on React islands, or Intersection Observer + CSS classes for Astro components
- All interactive components (animations, forms, toggles) must be React islands with `client:visible` or `client:load` directive
- Static Astro components do NOT need client directives
- Set `output: 'static'` in astro.config.mjs for static export
- Build command: `cd apps/web && pnpm build` (or `turbo build` from root)
- The build MUST succeed. If it fails, fix and retry.
- Use gradient/CSS backgrounds as video placeholders (no real video files needed — simulate with animated gradients)
STACKEOF
      ;;
    *)
      cat << 'STACKEOF'
- Stack: Next.js 14+ with App Router, TypeScript, Tailwind CSS, static export for Cloudflare Pages

**CRITICAL BUILD RULES:**
- Any page with useState, onClick, onChange, onSubmit, or any event handlers MUST have `'use client';` as the very first line
- Set `output: 'export'` and `images: { unoptimized: true }` in next.config
- Test with `npm run build` before pushing — it MUST succeed. If it fails, fix and retry.
STACKEOF
      ;;
  esac
}

STACK_BLOCK=$(get_stack_block "$CATEGORY")

cat << PROMPT
Build a complete ${NAME} web application and push it to GitHub.

**Project Details:**
- Name: ${NAME}
- Type: ${TYPE} — ${DESCRIPTION}
- Category: ${CATEGORY}
- Repo: devopseng99/${REPO} (already created, empty)
${STACK_BLOCK}
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
2. Initialize project with the specified stack
3. Build must succeed before pushing
4. Git commit and push to main
PROMPT
