const io = new IntersectionObserver((entries) => {
  entries.forEach((e) => {
    if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
  });
}, { threshold: 0.14 });
document.querySelectorAll('.reveal').forEach((el) => io.observe(el));

const icon = document.querySelector('.hero-icon');
window.addEventListener('pointermove', (e) => {
  const x = (e.clientX / window.innerWidth - 0.5) * 10;
  const y = (e.clientY / window.innerHeight - 0.5) * 10;
  if (icon) icon.style.transform = `translate(${x}px, ${y}px)`;
});

// Hero toy: the coffee drains like the menu-bar battery gauge; empty, the cat nods off. Close the
// lid and the Mac sleeps — unless "Keep awake on lid close" is on.
(() => {
  const $ = (id) => document.getElementById(id);
  if (!$('toy')) return;
  let coffee = 1, build = 0, lidClosed = false, lidMode = false, last = performance.now();
  const set = (id, attr, v) => $(id).setAttribute(attr, v);
  function note(t) { $('toyNote').textContent = t; }
  function frame(now) {
    const dt = Math.min(0.1, (now - last) / 1000); last = now;
    coffee = Math.max(0, coffee - dt * 0.06);
    const awakeByCoffee = coffee > 0.12;
    const macAwake = lidClosed ? lidMode && awakeByCoffee : awakeByCoffee;
    if (macAwake) build = Math.min(1, build + dt * 0.05);
    // coffee level and steam
    const h = 46 * coffee; set('coffee', 'y', 198 - h); set('coffee', 'height', h);
    $('steam').style.opacity = coffee > 0.12 ? 1 : 0;
    // drooping eyelids as the cup empties
    const droop = awakeByCoffee ? Math.max(0, (0.45 - coffee) / 0.33) : 1;
    set('lidL', 'height', 22 * Math.min(1, droop)); set('lidR', 'height', 22 * Math.min(1, droop));
    $('zzz').style.opacity = awakeByCoffee ? 0 : 0.6 + 0.4 * Math.sin(now / 300);
    // the laptop
    $('lid').style.transform = lidClosed ? 'scaleY(0.12)' : 'none';
    set('screen', 'fill', macAwake ? '#0f2416' : '#0f0b08');
    set('buildBar', 'width', 132 * build);
    $('screenText').textContent = !macAwake ? 'sleeping… zz' : build >= 1 ? 'build done ✓' : 'build ' + Math.round(build * 100) + '%';
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
  function pour() {
    coffee = 1;
    note(build >= 1 ? 'Build finished while the cat stayed awake. Purrfect. ☕' : 'Fresh coffee! Wide awake again.');
  }
  $('pour').onclick = pour; $('cup').addEventListener('click', pour);
  $('lidBtn').onclick = () => {
    lidClosed = !lidClosed;
    $('lidBtn').textContent = lidClosed ? 'Open the lid' : 'Close the lid';
    note(lidClosed ? (lidMode ? 'Lid shut, still running — that’s lid-close mode. ✨' : 'Lid shut… the Mac fell asleep. Turn on lid-close mode!') : 'Lid open again.');
  };
  $('lidMode').parentElement.onclick = () => {
    lidMode = !lidMode; $('lidMode').classList.toggle('on', lidMode);
    note(lidMode ? 'Lid-close mode on: close the lid, it keeps going.' : 'Lid-close mode off.');
  };
  setInterval(() => { if (coffee <= 0.12 && !/asleep|nodded/.test($('toyNote').textContent)) note('The cat nodded off. Tap the cup to wake it up!'); }, 500);
})();
