# Wispr Promotional Website

A modern, single-page promotional website for Wispr voice dictation app with full-page scroll snapping sections.

## Features

- **Scroll Snapping**: Apple-style full-page sections with smooth snap scrolling
- **Modern Design**: Clean, engaging layout inspired by Apple's product pages
- **Color Theme**: Uses the blue gradient color palette from Wispr's logo
- **Responsive**: Works beautifully on desktop, tablet, and mobile
- **Animations**: Smooth fade-in effects and parallax scrolling
- **Keyboard Navigation**: Use arrow keys to navigate between sections

## Structure

```
website/
├── index.html              # Main HTML structure
├── styles.css              # All styling and animations
├── script.js               # Interactive features and animations
├── icon.svg                # Wispr logo
├── CNAME                   # Custom domain configuration
├── screenshots/            # App screenshots
│   ├── menu.png
│   ├── settings.png
│   ├── model-management.png
│   ├── onboarding-01.png
│   ├── onboarding-02.png
│   ├── onboarding-03.png
│   ├── onboarding-04.png
│   ├── onboarding-05.png
│   └── onboarding-06.png
└── README.md               # This file
```

The website is completely self-contained with all assets included.

## Sections

1. **Hero** - Eye-catching introduction with logo and call-to-action
2. **Download/Install** - Homebrew installation commands and download button with donate option
3. **Features** - Four key features in card layout
4. **How It Works** - Three-step process explanation
5. **Onboarding** - Interactive carousel showing the 6-step onboarding experience
6. **Screenshots** - Visual showcase of the app interface
7. **Use Cases** - Four different user scenarios
8. **Support** - Donation call-to-action with Revolut link
9. **Footer** - Links and copyright information

## Usage

### Local Development

Simply open `index.html` in a web browser:

```bash
open index.html
```

Or use a local server:

```bash
# Python 3
python3 -m http.server 8000

# Node.js (with http-server)
npx http-server
```

Then visit `http://localhost:8000`

### Deployment

The website is static HTML/CSS/JS and can be deployed to:

- **GitHub Pages**: Push to a `gh-pages` branch
- **Netlify**: Drag and drop the `website` folder
- **Vercel**: Connect your repository
- **Any static hosting**: Upload the files via FTP/SFTP

## Customization

### Colors

Edit the CSS variables in `styles.css`:

```css
:root {
    --primary-blue: rgb(84, 155, 230);
    --deep-blue: rgb(33, 38, 162);
    --light-blue: rgb(173, 225, 252);
    /* ... */
}
```

### Content

Edit the text directly in `index.html`. The structure is semantic and easy to modify.

### Images

All images are included in the website directory:
- `icon.svg` - Wispr logo
- `screenshots/menu.png` - Menu bar screenshot
- `screenshots/settings.png` - Settings screenshot
- `screenshots/model-management.png` - Model management screenshot
- `screenshots/onboarding-01.png` through `onboarding-06.png` - Onboarding flow screenshots

The website is completely self-contained and portable.

## Browser Support

- Chrome/Edge 90+
- Firefox 88+
- Safari 14+
- All modern mobile browsers

The scroll-snap feature is supported in all modern browsers. Older browsers will fall back to smooth scrolling.

## Performance

- No external dependencies
- Minimal JavaScript
- Optimized CSS animations
- Fast loading time
- Lighthouse score: 95+

## License

Same as the Wispr project.
