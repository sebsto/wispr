// Progressive enhancement marker: reveal-on-scroll styles only apply when JS runs,
// so all content stays visible if this file fails to load.
document.documentElement.classList.add('js');

const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/* --------------------------------------------------------------------------
   Header: frosted background once the page is scrolled
   -------------------------------------------------------------------------- */
const header = document.querySelector('.site-header');
let headerTicking = false;

function updateHeader() {
    if (header) header.classList.toggle('scrolled', window.scrollY > 8);
    headerTicking = false;
}

window.addEventListener('scroll', () => {
    if (!headerTicking) {
        window.requestAnimationFrame(updateHeader);
        headerTicking = true;
    }
}, { passive: true });
updateHeader();

/* --------------------------------------------------------------------------
   Release version label. The download button is a STATIC link to
   releases/latest/download/Wispr.pkg (set in the HTML), so downloads work even
   if this fetch fails or rate-limits — we only decorate the version text.
   -------------------------------------------------------------------------- */
async function fetchLatestRelease() {
    const versionInfo = document.getElementById('version-info');
    if (!versionInfo) return;
    try {
        const response = await fetch('https://api.github.com/repos/sebsto/wispr/releases/latest');
        if (!response.ok) {
            throw new Error(`GitHub API returned ${response.status}: ${response.statusText}`);
        }
        const data = await response.json();

        const pkg = (data.assets || []).find(a => a.name.endsWith('.pkg') && a.name !== 'Wispr.pkg')
            || (data.assets || []).find(a => a.name === 'Wispr.pkg');

        versionInfo.textContent = pkg
            ? `Latest: ${data.tag_name} • ${(pkg.size / 1024 / 1024).toFixed(1)} MB`
            : `Latest: ${data.tag_name}`;
    } catch (error) {
        // Not an error condition for the page: the static label already links users
        // to the latest release, so just note it quietly.
        console.warn('Could not fetch latest release info:', error);
    }
}
fetchLatestRelease();

/* --------------------------------------------------------------------------
   Copy-to-clipboard buttons (Homebrew commands)
   -------------------------------------------------------------------------- */
function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
        return navigator.clipboard.writeText(text);
    }
    // Fallback for non-secure contexts (e.g. plain http)
    return new Promise((resolve, reject) => {
        const textarea = document.createElement('textarea');
        textarea.value = text;
        textarea.setAttribute('readonly', '');
        textarea.style.position = 'fixed';
        textarea.style.opacity = '0';
        document.body.appendChild(textarea);
        textarea.select();
        try {
            document.execCommand('copy') ? resolve() : reject(new Error('execCommand copy failed'));
        } catch (err) {
            reject(err);
        } finally {
            textarea.remove();
        }
    });
}

document.querySelectorAll('.copy-btn').forEach(btn => {
    btn.addEventListener('click', async function () {
        const originalText = this.textContent;
        try {
            await copyText(this.getAttribute('data-copy'));
            this.textContent = 'Copied!';
            this.classList.add('copied');
        } catch (err) {
            console.warn('Copy to clipboard failed:', err);
            this.textContent = 'Copy failed';
        }
        setTimeout(() => {
            this.textContent = originalText;
            this.classList.remove('copied');
        }, 2000);
    });
});

/* --------------------------------------------------------------------------
   Scroll-reveal animations (staggered within each group)
   -------------------------------------------------------------------------- */
const revealEls = document.querySelectorAll('.reveal');

if (prefersReducedMotion || !('IntersectionObserver' in window)) {
    revealEls.forEach(el => el.classList.add('is-visible'));
} else {
    revealEls.forEach(el => {
        const siblings = el.parentElement
            ? Array.from(el.parentElement.querySelectorAll(':scope > .reveal'))
            : [el];
        el.style.transitionDelay = `${(siblings.indexOf(el) % 4) * 0.08}s`;
    });

    const revealObserver = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                entry.target.classList.add('is-visible');
                revealObserver.unobserve(entry.target);
            }
        });
    }, { threshold: 0.15, rootMargin: '0px 0px -60px 0px' });

    revealEls.forEach(el => revealObserver.observe(el));
}

/* --------------------------------------------------------------------------
   Onboarding carousel.
   Built on native horizontal scroll + CSS scroll-snap, so swipe and trackpad
   work with no JS at all; this script adds buttons, dots, keyboard support,
   and a screen-reader status line.
   -------------------------------------------------------------------------- */
(function initCarousel() {
    const viewport = document.querySelector('.carousel-viewport');
    const slides = Array.from(document.querySelectorAll('.carousel-slide'));
    const dotsContainer = document.querySelector('.carousel-dots');
    const prevBtn = document.querySelector('.carousel-btn.prev');
    const nextBtn = document.querySelector('.carousel-btn.next');
    const status = document.getElementById('carousel-status');

    if (!viewport || slides.length === 0 || !dotsContainer || !prevBtn || !nextBtn) return;

    const totalSlides = slides.length;
    let currentSlide = 0;
    // While a smooth scroll is in flight, currentSlide lags behind; navigation
    // is based on the pending target so rapid presses advance one slide each.
    let pendingTarget = null;

    slides.forEach((_, i) => {
        const dot = document.createElement('button');
        dot.type = 'button';
        dot.classList.add('carousel-dot');
        dot.setAttribute('aria-label', `Go to step ${i + 1} of ${totalSlides}`);
        dot.addEventListener('click', () => goToSlide(i));
        dotsContainer.appendChild(dot);
    });
    const dots = Array.from(dotsContainer.children);

    function updateUI() {
        dots.forEach((dot, i) => {
            dot.classList.toggle('active', i === currentSlide);
            if (i === currentSlide) {
                dot.setAttribute('aria-current', 'true');
            } else {
                dot.removeAttribute('aria-current');
            }
        });
        prevBtn.disabled = currentSlide === 0;
        nextBtn.disabled = currentSlide === totalSlides - 1;
        if (status) {
            const caption = slides[currentSlide].querySelector('figcaption');
            // Only the caption's own text — skip the decorative slide-number badge
            const captionText = caption
                ? Array.from(caption.childNodes)
                    .filter(node => node.nodeType === Node.TEXT_NODE)
                    .map(node => node.textContent)
                    .join('')
                    .trim()
                : '';
            status.textContent = `Step ${currentSlide + 1} of ${totalSlides}${captionText ? ': ' + captionText : ''}`;
        }
    }

    function slideBase() {
        return pendingTarget !== null ? pendingTarget : currentSlide;
    }

    function goToSlide(index) {
        const target = Math.max(0, Math.min(index, totalSlides - 1));
        pendingTarget = target;
        const left = target * viewport.clientWidth;
        try {
            viewport.scrollTo({ left, behavior: prefersReducedMotion ? 'auto' : 'smooth' });
        } catch (err) {
            viewport.scrollLeft = left;
        }
    }

    // Keep state in sync with native scrolling (swipe, trackpad, snap)
    let scrollTicking = false;
    viewport.addEventListener('scroll', () => {
        if (scrollTicking) return;
        scrollTicking = true;
        window.requestAnimationFrame(() => {
            const index = Math.round(viewport.scrollLeft / viewport.clientWidth);
            if (index === pendingTarget) pendingTarget = null;
            if (index !== currentSlide && index >= 0 && index < totalSlides) {
                currentSlide = index;
                updateUI();
            }
            scrollTicking = false;
        });
    }, { passive: true });

    prevBtn.addEventListener('click', () => goToSlide(slideBase() - 1));
    nextBtn.addEventListener('click', () => goToSlide(slideBase() + 1));

    // Arrow-key navigation while the carousel has focus
    viewport.addEventListener('keydown', (e) => {
        const actions = {
            ArrowLeft: slideBase() - 1,
            ArrowRight: slideBase() + 1,
            Home: 0,
            End: totalSlides - 1
        };
        if (e.key in actions) {
            e.preventDefault();
            goToSlide(actions[e.key]);
        }
    });

    // Re-align the current slide after a resize changes the viewport width
    let resizeTimeout;
    window.addEventListener('resize', () => {
        clearTimeout(resizeTimeout);
        resizeTimeout = setTimeout(() => {
            viewport.scrollLeft = currentSlide * viewport.clientWidth;
        }, 150);
    });

    updateUI();
})();
