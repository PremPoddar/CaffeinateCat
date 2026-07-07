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
