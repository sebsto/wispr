# Website

A static, self-contained product website. No build step required.

## Deployment

This site is plain HTML/CSS/JS and can be deployed anywhere that serves static files:

- **GitHub Pages**: push the contents of `website/` to a `gh-pages` branch
- **Netlify**: drag and drop the `website` folder into the Netlify dashboard
- **Vercel**: connect your repository and set the root directory to `website`
- **Any static host**: upload the files via FTP/SFTP

## Customization

### Colors

Edit the CSS variables at the top of `styles.css`:

```css
:root {
  --primary-blue: rgb(84, 155, 230);
  --deep-blue: rgb(33, 38, 162);
  --light-blue: rgb(173, 225, 252);
  /* ... */
}
```

### Content

Edit the text directly in `index.html`. The structure is semantic and organized by section, so it's easy to find and change.

### Fonts

Headings use [Space Grotesk](https://fonts.google.com/specimen/Space+Grotesk) and body text uses [DM Sans](https://fonts.google.com/specimen/DM+Sans), loaded from Google Fonts in `index.html`. If the fonts can't load (e.g. offline), the site falls back to system fonts and remains fully usable. To change fonts, edit the `<link>` in `index.html` and the `--font-heading` / `--font-body` variables in `styles.css`.

### Images

All images live in the website directory:

- `icon.svg` — logo
- `screenshots/menu.png` — menu bar screenshot
- `screenshots/settings.png` — settings screenshot
- `screenshots/model-management.png` — model management screenshot
- `screenshots/onboarding-01.png` through `onboarding-06.png` — onboarding flow screenshots

The site is fully self-contained and portable — copy the `website/` folder anywhere and it works.

## Browser Support

- Chrome/Edge 90+
- Firefox 88+
- Safari 14+
- All modern mobile browsers

Scroll-snap is used for smooth section/carousel scrolling and is supported in all modern browsers; older browsers fall back to standard smooth scrolling.
