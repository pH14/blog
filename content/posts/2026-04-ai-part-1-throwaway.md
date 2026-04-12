+++
title = "On AI, Part I: Learning to Throw it All Away"
date = 2026-04-12
description = "Some early thoughts on learning to throw away what I know and what I do"

[extra]
toc = false
comment = false
+++

After a few years of management, in the last month or so I’ve returned to an IC role where I'm back to being hands-on-keyboard with code{% sidenote() %}Or something like that... I mean first, I've now adopted some amount of voice-to-text, so can I really say _hands-on-keyboard_? And am I actually working _with_ the code, when so often it's indirectly though an LLM? Anyway, moving on.{% end %}.

The last time I was really up close with the code, the hype cycle was around ChatGPT 3.5 and 4, and then Cursor. Lured by the occasionally impressive response or autocomplete, I'd try to build more and more of my projects with these tools, only to find flaws riddling every aspect of their work. I gave them an earnest shot, and each and every time I found that ye' ol' artisanal, handcrafted code was faster to write, and so, so much less annoying to work with.

Claude Code in 2026 though? Wow.

Though my return to ~~hands-on-keyboard~~ voice-to-microphone work has only been a month, I have yet to ~~handwrite~~ dictate an individual line of code, because I simply haven't needed to. Claude is just much better and faster than me at writing Rust.

The impact on my work, just a few weeks into this new world, has been profound. Having access to this tireless robot who is supremely skilled at producing syntactically correct code dramatically changes how I've been thinking about using my time, and where I direct my energy as I cling to the idea that I am still boss of the computer{% sidenote() %}I have rapidly developed a particular type of sigh when Claude has a distributed systems insight that I missed. I've already ceded writing code to it, I'm not ready for it take more away yet!{% end %}.

And while I continue to work through my existential angst of what comes of my career as LLMs rapidly commoditize a craft I’ve honed for the last 20 years, I have found working with Claude to be nothing short of exhilarating, reminiscent of the youthful glee I had in middle school when I first discovered how one could make things on a computer. I’ve been able to explore and probe problems from so many more angles than I ever had been able to before, delightfully dancing from thought to thought as Claude cranks out demos and discussion.

---

That ability to uncork experiments and capitalize on the moment inspiration strikes has been one of my favorite benefits from LLMs. I've always thought of software as an intensely creative pursuit, and there are always those moments when you need to go broad and just try things, or go deep and chase down some nagging line of thought, to eventually land at the right solution.

In recognizing the need for experimentation, my current employer has Skunkworks Fridays, where engineers can spend time on projects of personal interest {% sidenote() %}For those curious, the primary criteria of a skunkworks project: you should be able to tell a coworker what you are spending time on with pride, and, you must share your work.{% end %}. It's a great program, and has yielded a great many innovations (some trajectory-altering for the company), as engineers are given a time and place to play with ideas.

I recently wanted to explore how our storage engine might take advantage of tiered object storage: hot writes land in a low-latency single-zone bucket, background compaction writes landing in a slower multi-zone bucket. However as a follow-on, because the product has an expectation of multi-zone availability, you’d then want to introduce something like quorum reads and writes across multiple single-zone buckets to compensate for their reduced availability.

Either of these projects — tiered object storage writes, and quorum-backed zonal buckets — are good skunkworks opportunities of a bygone era. I could imagine waking up one Friday morning to a glorious meeting-less calendar, picking the one that spoke to me that day, and focusing heads-down, until, by the end of the day, I'd have a sketchy-but-functional prototype that I could proudly share with the class.

The new era is different. In the middle of the week the thought of the tiered storage experiment occurred to me while I was in-between other tasks. Rather than adding the ideas to my ever-growing skunkworks project list and saving for a future Friday, I instead dumped the buffered thoughts in my brain into a few short prompts for my local friendly robot. I had working prototypes for both projects within 15 minutes, having largely let Claude cook while I went to grab a snack{% sidenote() %}Medjool dates & roasted pecans have been hit lately.{% end %}. The results came so fast I almost didn't know what to do afterwards. Join the two changes together? Run some benchmarks? Do some cost modeling? Make a fancy demo? Clearly I wasn't being ambitious enough.

As LLMs have made the cost of experimentation so cheap, it has transformed their individual lines of code into pure ephemera. I didn't type the prompts in expecting to get enduring code, and the LLM, so proficient are producing write-only run-once code as its modus operandi, didn't produce enduring code. But that's often enough to prove a point, derisk an approach, make a fun demo to shop around, or just scratch an itch. And in the end, the code itself can be tossed--why keep it when it can be remade so quickly (probably by a better model in the future)?

Today, rather than my skunkworks project list forever growing with things I wish I could try, I now have a fun trail of prompts & demos that Claude has left behind. New experimental ideas for future, dedicated time are far more ambitious, composing the little building blocks accrued from each moment of inspiration along the way.

I'm still making sense of the new era, but, just as how most of the code Claude generates is bound for the dustbin, I can tell that my own software development playbook, built up over decades of practice, is being thrown away. The ability to build, permute, and play with ideas at the speed of thought has been thrilling, and at least for while I still have the occasional edge over the machine, I'm having fun.
