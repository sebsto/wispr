// Smooth scroll behavior for anchor links
document.querySelectorAll('a[href^="#"]').forEach(anchor => {
    anchor.addEventListener('click', function (e) {
        e.preventDefault();
        const target = document.querySelector(this.getAttribute('href'));
        if (target) {
            target.scrollIntoView({
                behavior: 'smooth',
                block: 'start'
            });
        }
    });
});

// Fetch latest release from GitHub
async function fetchLatestRelease() {
    try {
        const response = await fetch('https://api.github.com/repos/sebsto/wispr/releases/latest');
        
        // Check if response is OK (status 200-299)
        if (!response.ok) {
            throw new Error(`GitHub API returned ${response.status}: ${response.statusText}`);
        }
        
        const data = await response.json();
        
        const downloadLink = document.getElementById('download-link');
        const downloadText = document.getElementById('download-text');
        const versionInfo = document.getElementById('version-info');
        const footerDownloadLink = document.querySelector('.footer-links a[href*="releases"]');
        
        if (data.assets && data.assets.length > 0) {
            // Find the .dmg or .pkg file
            const asset = data.assets.find(a => a.name.endsWith('.dmg') || a.name.endsWith('.pkg')) || data.assets[0];
            const downloadUrl = asset.browser_download_url;
            
            // Update main download button (with null checks)
            if (downloadLink) downloadLink.href = downloadUrl;
            if (downloadText) downloadText.textContent = `Download ${data.tag_name}`;
            if (versionInfo) versionInfo.textContent = `Latest: ${data.tag_name} • ${(asset.size / 1024 / 1024).toFixed(1)} MB`;
            if (footerDownloadLink) footerDownloadLink.href = downloadUrl;
        } else {
            if (downloadLink) downloadLink.href = data.html_url;
            if (downloadText) downloadText.textContent = `View ${data.tag_name} on GitHub`;
            if (versionInfo) versionInfo.textContent = `Latest: ${data.tag_name}`;
            if (footerDownloadLink) footerDownloadLink.href = data.html_url;
        }
    } catch (error) {
        console.error('Failed to fetch latest release:', error);
        const downloadLink = document.getElementById('download-link');
        const versionInfo = document.getElementById('version-info');
        const footerDownloadLink = document.querySelector('.footer-links a[href*="releases"]');
        
        const fallbackUrl = 'https://github.com/sebsto/wispr/releases/latest';
        if (downloadLink) downloadLink.href = fallbackUrl;
        if (versionInfo) versionInfo.textContent = 'View releases on GitHub';
        if (footerDownloadLink) footerDownloadLink.href = fallbackUrl;
    }
}

// Copy to clipboard functionality
document.querySelectorAll('.copy-btn').forEach(btn => {
    btn.addEventListener('click', async function() {
        const textToCopy = this.getAttribute('data-copy');
        try {
            await navigator.clipboard.writeText(textToCopy);
            const originalText = this.textContent;
            this.textContent = 'Copied!';
            setTimeout(() => {
                this.textContent = originalText;
            }, 2000);
        } catch (err) {
            console.error('Failed to copy:', err);
        }
    });
});

// Call on page load
fetchLatestRelease();

// Intersection Observer for fade-in animations
const observerOptions = {
    threshold: 0.2,
    rootMargin: '0px 0px -100px 0px'
};

const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
        if (entry.isIntersecting) {
            entry.target.classList.add('visible');
        }
    });
}, observerOptions);

// Observe all feature cards, steps, and use cases
document.querySelectorAll('.feature-card, .step, .use-case, .screenshot-item').forEach(el => {
    el.style.opacity = '0';
    el.style.transform = 'translateY(30px)';
    el.style.transition = 'opacity 0.6s ease, transform 0.6s ease';
    observer.observe(el);
});

// Add visible class styling
const style = document.createElement('style');
style.textContent = `
    .visible {
        opacity: 1 !important;
        transform: translateY(0) !important;
    }
`;
document.head.appendChild(style);

// Add staggered animation delays
document.querySelectorAll('.feature-card').forEach((card, index) => {
    card.style.transitionDelay = `${index * 0.1}s`;
});

document.querySelectorAll('.step').forEach((step, index) => {
    step.style.transitionDelay = `${index * 0.15}s`;
});

document.querySelectorAll('.use-case').forEach((useCase, index) => {
    useCase.style.transitionDelay = `${index * 0.1}s`;
});

document.querySelectorAll('.screenshot-item').forEach((item, index) => {
    item.style.transitionDelay = `${index * 0.15}s`;
});

// Onboarding Carousel - Only initialize if elements exist
const slides = document.querySelectorAll('.onboarding-slide');
const track = document.querySelector('.carousel-track');
const dotsContainer = document.querySelector('.carousel-dots');
const prevBtn = document.querySelector('.carousel-btn.prev');
const nextBtn = document.querySelector('.carousel-btn.next');

if (slides.length > 0 && track && dotsContainer && prevBtn && nextBtn) {
    let currentSlide = 0;
    const totalSlides = slides.length;

    // Create dots
    for (let i = 0; i < totalSlides; i++) {
        const dot = document.createElement('button');
        dot.classList.add('carousel-dot');
        if (i === 0) dot.classList.add('active');
        dot.setAttribute('aria-label', `Go to slide ${i + 1}`);
        dot.addEventListener('click', () => goToSlide(i));
        dotsContainer.appendChild(dot);
    }

    const dots = document.querySelectorAll('.carousel-dot');

    function updateCarousel() {
        if (!track || slides.length === 0) return;
        
        const slideWidth = slides[0].offsetWidth;
        const gap = 32; // 2rem gap
        const offset = currentSlide * (slideWidth + gap);
        track.style.transform = `translateX(-${offset}px)`;
        
        // Update dots
        dots.forEach((dot, index) => {
            dot.classList.toggle('active', index === currentSlide);
        });
        
        // Update button states
        if (prevBtn) prevBtn.disabled = currentSlide === 0;
        if (nextBtn) nextBtn.disabled = currentSlide === totalSlides - 1;
    }

    function goToSlide(index) {
        currentSlide = Math.max(0, Math.min(index, totalSlides - 1));
        updateCarousel();
    }

    function nextSlide() {
        if (currentSlide < totalSlides - 1) {
            currentSlide++;
            updateCarousel();
        }
    }

    function prevSlide() {
        if (currentSlide > 0) {
            currentSlide--;
            updateCarousel();
        }
    }

    prevBtn.addEventListener('click', prevSlide);
    nextBtn.addEventListener('click', nextSlide);

    // Track if carousel is in view for keyboard navigation
    let carouselInView = false;
    const carouselObserver = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            carouselInView = entry.isIntersecting;
        });
    }, { threshold: 0.5 });

    const carousel = document.querySelector('.onboarding-carousel');
    if (carousel) {
        carouselObserver.observe(carousel);
    }

    // Keyboard navigation for carousel (only when in view)
    document.addEventListener('keydown', (e) => {
        if (carouselInView && (e.key === 'ArrowLeft' || e.key === 'ArrowRight')) {
            e.preventDefault();
            if (e.key === 'ArrowLeft') {
                prevSlide();
            } else if (e.key === 'ArrowRight') {
                nextSlide();
            }
        }
    });

    // Auto-advance carousel
    let autoAdvanceInterval;
    function startAutoAdvance() {
        // Clear any existing interval before starting a new one
        if (autoAdvanceInterval) {
            clearInterval(autoAdvanceInterval);
        }
        autoAdvanceInterval = setInterval(() => {
            if (currentSlide < totalSlides - 1) {
                nextSlide();
            } else {
                currentSlide = 0;
                updateCarousel();
            }
        }, 5000);
    }

    function stopAutoAdvance() {
        if (autoAdvanceInterval) {
            clearInterval(autoAdvanceInterval);
            autoAdvanceInterval = null;
        }
    }

    // Start/stop auto-advance based on visibility
    const autoAdvanceObserver = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                startAutoAdvance();
            } else {
                stopAutoAdvance();
            }
        });
    }, { threshold: 0.5 });

    if (carousel) {
        autoAdvanceObserver.observe(carousel);
        carousel.addEventListener('click', stopAutoAdvance);
        carousel.addEventListener('touchstart', stopAutoAdvance);
    }

    // Update carousel on window resize (throttled)
    let resizeTimeout;
    window.addEventListener('resize', () => {
        clearTimeout(resizeTimeout);
        resizeTimeout = setTimeout(updateCarousel, 150);
    });
}

// Consolidated scroll handler with requestAnimationFrame throttling
let scrollTicking = false;

function handleScroll() {
    const scrollY = window.scrollY;
    
    // Hide scroll indicator when user scrolls
    const scrollIndicator = document.querySelector('.scroll-indicator');
    if (scrollIndicator) {
        if (scrollY > 100) {
            scrollIndicator.style.opacity = '0';
            scrollIndicator.style.pointerEvents = 'none';
        } else {
            scrollIndicator.style.opacity = '0.7';
            scrollIndicator.style.pointerEvents = 'auto';
        }
    }
    
    // Parallax effect for hero background
    const hero = document.querySelector('.hero');
    if (hero) {
        const heroHeight = hero.offsetHeight;
        if (scrollY < heroHeight) {
            hero.style.transform = `translateY(${scrollY * 0.5}px)`;
            hero.style.opacity = 1 - (scrollY / heroHeight) * 0.5;
        }
    }
    
    scrollTicking = false;
}

window.addEventListener('scroll', () => {
    if (!scrollTicking) {
        window.requestAnimationFrame(handleScroll);
        scrollTicking = true;
    }
});

// Section keyboard navigation (only when carousel not in view)
document.addEventListener('keydown', (e) => {
    // Skip if carousel is in view
    const carousel = document.querySelector('.onboarding-carousel');
    if (carousel) {
        const rect = carousel.getBoundingClientRect();
        const carouselVisible = rect.top >= -100 && rect.top <= window.innerHeight;
        if (carouselVisible) return;
    }
    
    const sections = document.querySelectorAll('.section');
    const currentSection = Array.from(sections).findIndex(section => {
        const rect = section.getBoundingClientRect();
        return rect.top >= -100 && rect.top <= 100;
    });

    if (e.key === 'ArrowDown' && currentSection < sections.length - 1) {
        e.preventDefault();
        sections[currentSection + 1].scrollIntoView({ behavior: 'smooth' });
    } else if (e.key === 'ArrowUp' && currentSection > 0) {
        e.preventDefault();
        sections[currentSection - 1].scrollIntoView({ behavior: 'smooth' });
    }
});

// Add loading animation
window.addEventListener('load', () => {
    const computedOpacity = window.getComputedStyle(document.body).opacity;
    // Only apply fade-in if the body was initially hidden via CSS (opacity 0)
    if (computedOpacity === '0') {
        document.body.style.transition = 'opacity 0.5s ease';
        window.requestAnimationFrame(() => {
            document.body.style.opacity = '1';
        });
    }
});
