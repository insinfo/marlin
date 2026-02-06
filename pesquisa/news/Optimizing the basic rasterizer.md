Follow:
RSS
Twitter
The ryg blogWhen I grow up I'll be an inventor.
Home
About
Coding
Compression
Computer Architecture
Demoscene
Graphics Pipeline
Maths
Multimedia
Networking
Papers
Stories
Thoughts
Uncategorized
Optimizing the basic rasterizer
February 10, 2013
This post is part of a series – go here for the index.

Last time, we saw how to write a simple triangle rasterizer, analyzed its behavior with regard to integer overflows, and discussed how to modify it to incorporate sub-pixel precision and fill rules. This time, we’re going to make it run fast. But before we get started, I want to get one thing out of the way:

Why this kind of algorithm?
The algorithm we’re using basically loops over a bunch of candidate pixels and checks whether they’re inside the triangle. This is not the only way to render triangles, and if you’ve written any software rendering code in the past, chances are good that you used a scanline rasterization approach instead: you scan the triangle from top to bottom and determine, for each scan line, where the triangle starts and ends along the x axis. Then we can just fill in all the pixels in between. This can be done by keeping track of so-called active edges (triangle edges that intersect the current scan line) and tracking their intersection point from line to line using what is essentially a modified line-drawing algorithm. While the high-level overview is easy enough, the details get fairly subtle, as for example the first two articles from Chris Hecker’s 1995-96 series on perspective texture mapping explain (links to the whole series here).

More importantly though, this kind of algorithm is forced to work line by line. This has a number of annoying implications for both modern software and hardware implementations: the algorithm is asymmetrical in x and y, which means that a very skinny triangle that’s mostly horizontal has a very different performance profile from one that’s mostly vertical. The outer scanline loop is serial, which is a serious problem for hardware implementations. The inner loop isn’t very SIMD-friendly – you want to be processing aligned groups of several pixels (usually at least 4) at once, which means you need special cases for the start of a scan line (to get up to alignment), the end of a scan line (to finish the last partial group of pixels), and short lines (scan line is over before we ever get to an aligned position). Which makes the whole thing even more orientation-dependent. If you’re trying to do mip mapping at the same time, you typically work on “quads”, groups of 2×2 pixels (explanation for why is here). Now you need to trace out two scan lines at the same time, which boils down to keeping track of the current scan conversion state for both even and odd edges separately. With two lines instead of one, the processing for the starts and end of a scan line gets even worse than it already is. And let’s not even talk about supporting pixel sample positions that aren’t strictly on a grid, as for example used in multisample antialiasing. It all goes downhill fast.

I think I’ve made my point: while scan-line rasterization works great when you’re working one scan line at a time anyway, it gets hairy quickly once throw additional requirements such as “aligned access”, “multiple rows at a time” or “variable sample position” into the mix. And it’s not very parallel, which hamstrings our ability to harness wide SIMD or build efficient hardware for it. In contrast, the algorithm we’ve been discussing is embarrassingly parallel – you can test as many pixels as you want at the same time, you can use arbitrary sample locations, and if you have specific alignment requirements, you can test pixels in groups that satisfy those requirements easily. There’s a lot to be said for those properties, and indeed they’ve proven convincing enough that by now, the edge function approach is the method of choice in high-performance software rasterizers – in graphics hardware, it’s been in use for a good while longer, starting in the late 80s (yes, 80s – not a typo). I’ll talk a bit more about the history later.

Right, however, now we still perform two multiplies and five subtractions per edge, per pixel. SIMD and dedicated silicon are one thing, but that’s still a lot of work for a single pixel, and it most definitely was not a practical way to perform hardware rasterization in 1988. What we need to do now is drastically simplify our inner loop. Luckily, we’ve seen everything we need to do that already.

Simplifying the rasterizer
If you go back to “The barycentric conspiracy”, you’ll notice that we already derived an alternative formulation of the edge functions by rearranging and simplifying the determinant expression:

F_{01}(p) = (v_{0y} - v_{1y}) p_x + (v_{1x} - v_{0x}) p_y + (v_{0x} v_{1y} - v_{0y} v_{1x})

Now, to reduce the amount of noise, let’s give those terms in parentheses names:

A_{01} := v_{0y} - v_{1y}
B_{01} := v_{1x} - v_{0x}
C_{01} := v_{0x} v_{1y} - v_{0y} v_{1x}

And if we split p into its x and y components, we get:

F_{01}(p_x, p_y) = A_{01} p_x + B_{01} p_y + C_{01}

Now, in every iteration of our inner loop, we move one pixel to the right, and for every scan line, we move one pixel up or down (depending on which way your y axis points – note I haven’t bothered to specify that yet!) from the start of the previous scan line. Both of these updates are really easy to perform since F01 is an affine function and we’re stepping along the coordinate axes:

F_{01}(p_x + 1, p_y) - F_{01}(p_x, p_y) = A_{01}
F_{01}(p_x, p_y + 1) - F_{01}(p_x, p_y) = B_{01}

In words, if you go one step to the right, add A01 to the edge equation. If you step down/up (whichever direction +y is in your coordinate system), add B01. That’s it. That’s all there is to it.

In our basic triangle rasterization loop, this turns into something like this: (I’ll keep using the original orient2d for the initial setup so we can see the similarity):

    // Bounding box and clipping as before
    // ...

    // Triangle setup
    int A01 = v0.y - v1.y, B01 = v1.x - v0.x;
    int A12 = v1.y - v2.y, B12 = v2.x - v1.x;
    int A20 = v2.y - v0.y, B20 = v0.x - v2.x;

    // Barycentric coordinates at minX/minY corner
    Point2D p = { minX, minY };
    int w0_row = orient2d(v1, v2, p);
    int w1_row = orient2d(v2, v0, p);
    int w2_row = orient2d(v0, v1, p);

    // Rasterize
    for (p.y = minY; p.y <= maxY; p.y++) {
        // Barycentric coordinates at start of row
        int w0 = w0_row;
        int w1 = w1_row;
        int w2 = w2_row;

        for (p.x = minX; p.x <= maxX; p.x++) {
            // If p is on or inside all edges, render pixel.
            if (w0 >= 0 && w1 >= 0 && w2 >= 0)
                renderPixel(p, w0, w1, w2);     

            // One step to the right
            w0 += A12;
            w1 += A20;
            w2 += A01;
        }

        // One row step
        w0_row += B12;
        w1_row += B20;
        w2_row += B01;
    }
And just like that, we’re down to three additions per pixel. Want proper fill rules? As we saw last time, we can do that using a single bias that we add to the edge functions, and we only have to add it once, at the start. Sub-pixel precision? Again, a bit more work during triangle setup, but the inner loop stays the same. Different pixel center? Turns out that’s just a bias applied once too. Want to sample at several locations within a pixel? That also turns into just another add and a sign test.

In fact, after triangle setup, it’s really mostly adds and sign tests no matter what we do. That’s why this is a popular algorithm for hardware implementation – you don’t even need to do the compare explicitly, you just use a bunch of adders and route the MSB (most significant bit) of the sum, which contains the sign bit, to whoever needs to know whether the pixel is in or not.

And on the subject of signs, there’s a small trick in software implementations to simplify the sign-testing part: as I just said, all we really need is the sign bit. If it’s clear, we know the value is positive or zero, and if it’s set, we know the value is negative. In fact, this is why I made the initial rasterizer test for >= 0 in the first place – you really want to use a test that only depends on the sign bit, and not something slightly more complicated like > 0. Why do we care? Because it allows us to rewrite the three sign tests like this:

    // If p is on or inside all edges, render pixel.
    if ((w0 | w1 | w2) >= 0)
        renderPixel(p, w0, w1, w2);     
To understand why this works, you only need to look at the sign bits. Remember, if the sign bit is set in a value, that means it’s negative. If, after ORing the three values together, they still register as non-negative, that means none of them had the sign bit set – which is exactly what we wanted to test for. Rewriting the expression like this turns three conditional branches into one – always a good idea to keep the flow control in inner loops simple if you want the optimizer to be happy, and it usually also turns out to be beneficial in terms of branch prediction, although I won’t bother to profile it here.

Processing multiple pixels at once
However, as fun as squeezing individual integer instructions is, the main reason I cited for using this algorithm is that it’s embarrassingly parallel, so it’s easy to process multiple pixels at the same time using either dedicated silicon (in hardware) or SIMD instructions (in software). In fact, all we really have to do is keep track of the current value of the edge equations for each pixel, and then update them all per pixel. For concreteness, let’s stick with 4-wide SIMD (e.g. SSE2). I’m going to assume that there’s a data type Vec4i for 4 signed integers in a SIMD registers that overloads the usual arithmetic operations to be element-wise, because I don’t want to use the official Intel intrinsics here (way too much clutter to see what’s going on).

For starters, let’s assume we want to process 4×1 pixels at a time – that is, in groups 4 pixels wide, but only one pixel high. But before we do anything else, let me just pull all the per-edge setup into a single function:

struct Edge {
    // Dimensions of our pixel group
    static const int stepXSize = 4;
    static const int stepYSize = 1;

    Vec4i oneStepX;
    Vec4i oneStepY;

    Vec4i init(const Point2D& v0, const Point2D& v1,
               const Point2D& origin);
};

Vec4i Edge::init(const Point2D& v0, const Point2D& v1,
                 const Point2D& origin)
{
    // Edge setup
    int A = v0.y - v1.y, B = v1.x - v0.x;
    int C = v0.x*v1.y - v0.y*v1.x;

    // Step deltas
    oneStepX = Vec4i(A * stepXSize);
    oneStepY = Vec4i(B * stepYSize);

    // x/y values for initial pixel block
    Vec4i x = Vec4i(origin.x) + Vec4i(0,1,2,3);
    Vec4i y = Vec4i(origin.y);

    // Edge function values at origin
    return Vec4i(A)*x + Vec4i(B)*y + Vec4i(C);
}
As said, this is the setup for one edge, but it already includes all the “magic” necessary to set it up for SIMD traversal. Which is really not much – we now step in units larger than one pixel, hence the oneStep values instead of using A and B directly. Also, we now return the edge function value at the specified “origin” directly; this is the value we previously computed with orient2d. Now that we’re processing 4 pixels at a time, we also have 4 different initial values. Note that I write Vec4i(value) for a single scalar broadcast into all 4 SIMD lanes, and Vec4i(a, b, c, d) for a 4-int vector that initializes the lanes to different values. I hope this is readable enough.

With this factored out, the SIMD version for the rest of the rasterizer is easy enough:

    // Bounding box and clipping again as before

    // Triangle setup
    Point2D p = { minX, minY };
    Edge e01, e12, e20;

    Vec4i w0_row = e12.init(v1, v2, p);
    Vec4i w1_row = e20.init(v2, v0, p);
    Vec4i w2_row = e01.init(v0, v1, p);

    // Rasterize
    for (p.y = minY; p.y <= maxY; p.y += Edge::stepYSize) {
        // Barycentric coordinates at start of row
        Vec4i w0 = w0_row;
        Vec4i w1 = w1_row;
        Vec4i w2 = w2_row;

        for (p.x = minX; p.x <= maxX; p.x += Edge::stepXSize) {
            // If p is on or inside all edges for any pixels,
            // render those pixels.
            Vec4i mask = w0 | w1 | w2;
            if (any(mask >= 0))
                renderPixels(p, w0, w1, w2, mask);

            // One step to the right
            w0 += e12.oneStepX;
            w1 += e20.oneStepX;
            w2 += e01.oneStepX;
        }

        // One row step
        w0_row += e12.oneStepY;
        w1_row += e20.oneStepY;
        w2_row += e01.oneStepY;
    }
There’s a bunch of surface changes – our edge function values are now Vec4is instead of ints, and we now process multiple pixels at a time – but the only thing that really changes in any way that matters is the switch from renderPixel to renderPixels: we now process multiple pixels at a time, and some of them could be in while others are out, so we can’t do a single if anymore. Instead, we pass our mask to renderPixels – which can then use the corresponding sign bit for each pixel to decide whether to update the frame buffer for that pixel. We only early-out if all of the pixels are outside the triangle.

But really, the most important thing to note is that this wasn’t hard at all! (At least I hope it wasn’t. Apologies if I’m going too fast.)

Next steps and a bit of perspective
At this point, I could spend an arbitrary amount of time tweaking our toy rasterizer, adding features, optimizing it and so forth, but I’ll leave it be; it’s served its purpose, which was to illustrate the underlying algorithm. We’re gonna switch back to the actual rasterizer from Intel’s Software Occlusion Culling demo next. But before we go there, I want to give you some more context about this kind of algorithm, where it’s coming from, and how you would modify it for practical applications.

First, as I mentioned before, the nice thing about this type of rasterizer is that it’s easy to incorporate external constraints. For example, try modifying the above code so it always does “aligned” accesses, i.e. the x-coordinate passed to renderPixels is always a multiple of 4. This enables the use of aligned loads and stores, which are faster. Similarly, try modifying the rasterizer to traverse groups of 2×2 pixels instead of 4×1 pixels; the code is set up in a way that should make this an easy change. Then combine the two things – traverse groups of aligned quads, i.e. x and y coordinates passed to renderPixels are always even. The point is that all these changes are actually easy to make, whereas they would be relatively hard to incorporate in a scanline rasterizer. It’s also easy to make use of wider instruction sets: you could do groups of 4×2 pixels, or 2×4, or even 4×4 and more if you wanted.

That said, the current outer loop we use – always checking the whole bounding box of the triangle – is hardly optimal. In fact, for any triangle that’s not so large it gets clipped to the screen edges, at least half of the bounding box is going to be empty. There are much better ways to do this traversal, but we’re not going to use any of the fancier strategies in this series (at least, I don’t plan to at this moment) since the majority of triangles we’re going to encounter in the demo are actually quite small. The better strategies are much more efficient at rasterizing large triangles, but if a triangle touches less than 10 pixels to begin with, it’s just not worth the effort to spend extra time on trying to only cover the areas of the triangle that matter. So there’s a fairly delicate balancing act involved. The code on Github does contain a branch that implements a hierarchical rasterizer, and while as of this writing it is somewhat faster, it’s not really enough of a win to justify the effort that went into it. But it might still be interesting if you want to see how a (quickly hacked!) version of that approach looks.

Which brings me to the history section: As I mentioned in the introduction, this approach is anything but new. The first full description of it in the literature that I’m aware of is Pineda’s “A Parallel Algorithm for Polygon Rasterization”. It was presented at Siggraph 1988 and already describes most of the ideas: It uses integer edge functions, has the incremental evaluation, sub-pixel precision (but no proper fill rule), and it produces blocks of 4×4 pixels at a time. It also shows several smarter traversal algorithms than the basic bounding box strategy we’re using. McCormack and McNamara describe more efficient traversal schemes based on tiles, Greene’s “Hierarchical Polygon Tiling with Coverage Masks” describes a hierarchical approach, Michael Abrash’s “Rasterization on Larrabee” describes the same approach as independently discovered while working on Larrabee (I later joined that team, which is a good part of the reason for me being able to quote this list of references by heart), and McCool et al. describe a combination of hierarchical rasterization and Hilbert curve scan order that should be sufficient to nerd snipe you for at least half an hour if you’re still clicking on those links. Olano and Greer even describe an algorithm that rasterizes straight from homogeneous coordinates without dividing the vertex coordinates through by w first that everyone interested either in rasterization or projective geometry should check out.

Did I mention that this approach isn’t exactly new? Anyway, this tangent has gone on for long enough; let’s go back to the Software Occlusion Culling demo.

A match made in Github
I’m not going to start describing any new techniques here, but I do want to use the rest of this article to link up my description of the algorithm with the code in the Software Occlusion Culling demo, so you know what goes where. I purposefully picked our notation and terminology to be similar to the rasterizer code, to minimize friction. I’ll write down differences as we encounter them. One thing I’ll point out right now is that this code has y pointing down, whereas all my diagrams so far had y=up (note that I was fairly dodgy in the last 2 posts about which way y actually points – this is why). This is a fairly superficial change, but it does mean that the triangles with positive area are now the clockwise ones. Keep that in mind. Also, apologies in advance for the messed-up spacing in the code I’m linking to – it was written for 4-column tabs and mixes tabs and spaces, so there’s the usual display problems. (This is why I prefer using spaces in my code, at least in code I intend to put on the net)

The demo uses a “binning” architecture, which means the screen is chopped up into a number of rectangles (“tiles”), each 320×90 pixels. Triangles first get “binned”, which means that for each tile, we build a list of triangles that (potentially) overlap it. This is done by the binner.

Once the triangles are binned, this data gets handed off to the actual rasterizer. Each instance of the rasterizer processes exactly one tile. The idea is that tiles are small enough so that their depth buffer (which is what we’re rasterizing, since we want it for occlusion culling) fits comfortably within the L2 cache of a core. By rendering one tile at a time, we should thus keep number of cache misses for the depth buffer to a minimum. And it works fairly well – if you look at some of the profiles in earlier articles, you’ll notice that the depth buffer rasterizer doesn’t have a high number of last-level cache misses, even though it’s one of the main workhorse functions in the program.

Anyway, the rasterizer first tries to grabs a group of 4 triangles from its active bin (a “bin” is a container for a list of triangles). These triangles will be rendered sequentially, but they’re all set up as a group using SIMD instructions. The first step is to compute the A’s, B’s and C’s and determine the bounding box, complete with clipping to the tile bounds and snapping to 2×2-aligned pixel positions. This is now written using SSE2 intrinsics, but the math should all look very familiar at this point.

It also computes the triangle area (actually, twice its area) which the barycentric coordinates later get divided by to normalize them.

Then, we enter the per-triangle loop. Mostly, variables get broadcast into SIMD registers first, followed by a bit more setup for the increments and of course the initial evaluation of the edge functions (this looks all scarier than it is, but it is fairly repetitive, which is why I introduced the Edge struct in my version of the same code). Once we enter the y-loop, things should be familiar again: we have our three edge function values at the start of the row (incremented whenever we go down one step), and the per-pixel processing should look familiar too.

After the early-out, we have the actual depth-buffer rendering code – the part I always referred to as renderPixels. The interpolated depth value is computed from the edge functions using the barycentric coordinates as weights, and then there’s a bit of logic to read the current value from the depth buffer and update it given the interpolated depth value. The ifs are there because this loop supports two different depth storage formats: a linear one that is used in “visualize depth buffer” mode and a (very simply) swizzled format that’s used when “visualize depth buffer” is disabled.

So everything does, in fact, closely follow the basic code flow I showed you earlier. There’s a few simple details that I haven’t explained yet (such as the way the depth buffer is stored), but don’t worry, we’ll get there – next time. No more delays – actual changes to the rasterizer and our first hard-won performance improvements are upcoming!

Related
A trip through the Graphics Pipeline 2011, part 6
July 6, 2011
In "Coding"
Triangle rasterization in practice
February 8, 2013
In "Coding"
A trip through the Graphics Pipeline 2011, part 5
July 5, 2011
In "Coding"
From → Coding

29 Comments
Marco Mustapic's avatar
Marco Mustapic permalink
I was always convinced that the scan line algorithm was the one implemented in the old accelerator cards and GPUs. After reading the previous article I wanted to ask you the advantages of the edge algorithm, and luckily this post answers that :)

I also remember (correctly?) that the first 3dfx Voodoo just rendered scan lines in hardware, and then the Voodoo 2 introduced a “triangle setup engine”. Did that hw compute the same you do in Edge::init? Could that account for the huge difference in performance between the Voodoo and the Voodoo 2 (besides the clock speed)?

Reply
fgiesen's avatar
fgiesen permalink
I don’t know what the Voodoo chips did internally, but I’m trying to find out. I’ll add another reply once I know more.

Either way, triangle setup in HW rasterizers has additional responsibilities. I’ve shown only the part necessary to trace out the triangle itself; a general-purpose rasterizer also performs setup computations for Z interpolation (which we’ll see one variant of) and perspective correction (which I won’t cover in this series). And of course there’s also setup for additional interpolated quantities (colors, texture coordinates, and so forth). As long as there’s just a fixed, small number of them, it makes sense to interpolate them directly, but it quickly gets unwieldy. Modern designs just pass barycentric coordinates to the shaders and let them perform the interpolation themselves. There’s still a bit of setup work for the attributes (computing the edge differences), but that’s not necessarily performed at the same time as setup for the other quantities.

I very much doubt that the performance difference between Voodoo and Voodoo2 had anything to do with the way they rasterized triangles. At the time, the number of triangles on the screen was in the few hundreds to low thousands. Even factoring in the lower resolutions at the time, that means well over a hundred pixels for the average triangle. They could output 1 pixel/clock, and the bottleneck was most certainly their texture mapping / pixel pipeline, not the rasterizer.

In any parallel system, the serial parts will end up becoming the bottleneck as you improve the rest (or just improve the amount of parallelism) – that’s just Amdahl’s law. Once serial scanline rasterizers became a bottleneck, they got replaced with more intrinsically parallel algorithms. I can’t tell you exactly when that happened for the different vendors though. :)

Reply
Marco Mustapic's avatar
Marco Mustapic permalink
I googled a bit and found register specifications docs for Voodoo and Voodoo2, and also looked into the source code of Glide drivers for Linux.

Apparently, to render one triangle on the original Voodoo one had to specify 3 vertices, triangle orientation, initial values for parameters like colors, texture coordinates, z, fog, and gradients (increments) for those same parameters on x and y. Glide could compute the gradients on behalf of the programmer. The chip would then render the triangle, although I couldn’t find what the hw does exactly.

Voodoo2 on the other had could compute these gradients in hw, and had support for triangle strips and fans (rendering a new triangle with just one additional vertex).

Thanks for the reply, and for your great posts. All this low level info helps me understand better why things are the way they are on the api and software side.

fgiesen's avatar
fgiesen permalink
Okay, my colleague Brian Hook (original implementer of Glide) put me in touch with Gary Tarolli, former CTO of 3dfx, who actually designed the Voodoo rasterizer. Here’s what he wrote:

Voodoo 1 and 2 used Pineda-style setup and rasterization. There was no loss of precision – integer in/out variables were used. They did rasterize in scanlines, but not like the typical scanline rasterizers which iterated things down the edges and then computed slopes across the scanline. Voodoo chips computed dx and dy increments and so could rasterize in any directions. In fact, Voodoo 1 and 2 I believe rasterized left-to-right and then right-to-left (after proceeding down 1 unit). In later chips we modified the traversal to be more friendly to the texture cache and so rasterization , albeit a single pixel at a time, worked in small screen tiles. I also remember some optimizations we implemented to “remember” the last inside pixel in the scanline below, so that for nearly flat edges we wouldn’t have to scan unnecessarily outside the triangle.

So I would not call them “classic” scanline rasterizers. I would define “classic” as machines that computed slopes per edge using division, and then slopes for the scanline using division again. This loss of precision is bad and the source of cracks and overdraws. Voodoo chips had none of that, the edge equations were precise. The fact that the pattern it followed was originally scanline oriented was only due to the fact that it was a single pixel rasterizer and a choice. Triangle parameters were however inprecise.

I don’t know if we ever released the software Glide source code – I developed that before the chips to perfect all the algorithms. We also used that in testing the chips – as we compared the hardware results to the software simulation results. If you can find that source code you will have all the details.

Also – if you look at the Voodoo1 register set, you can see the edge equation parameters. In fact the Glide code shows you all the setup math. In Voodoo2 we put that into hardware, but it was the exact same math. We also did sub-pixel correction etc. The only thing you don’t see is the stepping algorithm, but it is similar to what is in your article. The rasterizer proceeds 1 step in either X or Y and adjusts all the edge equations and triangle parameters by the dx or dy value. How it decides to start/stop/reverse/change_direction is where the fun is. The 3 edge equations (or 4 if you want to rasterize lines or quads) nicely tell you if you are in/out of the triangle, but deciding upon the traversal path is where chips will differ. Do you reverse direction or jump back, do you look-ahead in either X or Y, do you superimpose tiles, e.g. 4×4 or 8×8 , even for single pixel rasterizing? These are all the details that will differentiate rasterizers.

Straight from the horse’s mouth. Thanks Gary for the very detailed answer and thanks Brian for introducing me to him!

Reply
Trixter's avatar
Trixter permalink
You remember the old days. For systems without multithreaded support or SIMD, would you still recommend these methods, or suggest going back to scanline rasterization? (with the knowledge that the modern method you described above nicely solves the overdraw problem that scanline rasterization had)

Reply
fgiesen's avatar
fgiesen permalink
Whoa there, what “overdraw problem” are you talking about? You mean pixels getting lit multiple times (or dropped) at edges where triangles meet? Because that’s not a problem with scanline rasterization, that’s a bug in most implementations of the algorithm. A scanline rasterizer can precisely follow the exact same top-left fill rule, but you need to be careful. Chris Hecker’s articles (that I linked to) explain how.

Lack of dedicated SIMD instructions doesn’t mean you can’t do SIMD – you can still pack multiple values inside an integer register! :) That said, compared to classic scanline rasterizers the basic rasterizer I show does need to update the edge equations for every pixel, which adds a lot of register pressure. Unless you can actually generate multiple pixels at the same time, you’re not getting much advantage from this approach.

One thing I don’t talk about is the ability of edge function rasterizers to quickly decide whether any given axis-aligned rectangle is fully inside, fully outside or partially inside a given edge. This can be used to step in much larger units (e.g. 4×4 or 8×8 pixels at a time), rejecting lots of empty space at a time. It also means you can identify large solid blocks of pixels quickly. The article by Michael Abrash has some explanation and accompanying images. This one is potentially interesting since you can use it to perform “on-the-fly” bandwidth reduction for flat-shaded scenes: keep track of which blocks of say 8×8 pixels are solid-colored, and then the next frame that renders to that location can quickly determine whether you’re about to write the same color again and skip writing it altogether. This might be interesting for machines like Amigas with 68050/68060s that are commonly limited by chip memory bandwidth. You could do a similar thing on oldschool PCs with slow VGAs. (And also exploit Mode X’s ability to write 4 pixels at a time). I’ve never actually tried implementing any of this on oldschool machines though.

Reply
Trixter's avatar
Trixter permalink
Thanks for the reply. I think that it is still too much housekeeping for an oldschool PC. if I’m only drawing 10 triangles take take up a quarter of the screen, it is hard for me to justify all the tests (on my platform anyway, the registers are tiny and few). But very interesting reading, thank you for spending the time. You touched on this on your Exploring the Graphics Pipeline series but it’s nice to see this zoomed in on with more detail.

noop's avatar
noop permalink
I wrote SW rasteriser once for my PS1 GPU emulation plugin, using a lot of inline MMX assembler. Can say that non-scanline approach is only useful when you can do a lot of stuff in parallel and value precision over RAW speed. Carefully constructed scanline rasterizer is hard(impossible) to beat on conventional CPU. BTW my approach was different from some naive implementations. I used vertical and horizontal interpolation increments instead of per-edge increments, for example.
Also had unfinished implementation that used tile buffer that fits L1 cache and swizzled textures.

Reply
fgiesen's avatar
fgiesen permalink
What I’m describing here is focused on handling relatively small triangles. Something intended to deal with larger triangles will include a hierarchical traversal that allows it to not evaluate the edge equations for most of the interior of triangles, for example.

Never say “impossible”. :) That entirely depends. It’s quite easy to do hierarchical Z-reject on large blocks of pixels at a time with an edge equation rasterizer, for example. Doing the same with scanline rasterization is fairly impractical. Of course, the PS1 doesn’t do any hardware Z-buffering :)

Using per-pixel increments is faster (and I’ll get there later in the series), but it’s also noticeably less accurate.

PS1 only has a few interpolated quantities. For more general shaders, you can easily have 16+ separate interpolated values over a triangle, and you just can’t keep the values and increments in the registers anymore. So you just determine (perspective corrected) barycentric coordinates once and do a bit more math per pixel to do the interpolation. Again somewhat moot because the PS1 doesn’t do perspective correction either.

noop's avatar
noop permalink
Well, I intended to use question mark after “impossible”, sorry for that. When you write stuff like this using half of your brain you frequently become embarrassed 1 second after pressing “Post” button.
Back to subject.
First, I’m also mostly concerned about average 100-pixel triangles. Good PS1 game can have a few thousands per frame in low res, so they are not that huge.
Huge triangles are easy targets for optimization tricks. Hierarchical HSR works well, yes, but it is sort of corner case, big triangles are already fast, because you spend much more time in inner loop of conventional rasterizer.
Fact that you can reject bigger blocks of pixes when drawing non-transparent big triangles doesn’t change the fact that when you actually have to draw those pixels, scanline rasterization is more efficient use of CPU registers and ALU.

About precision of increments.. In my case I estimated maximum error and made sure it never gets noticed and causes no overflows. That was sufficient. If you can’t allocate enough bits, you can always subdivide bigger triangles for negligible cost.
If you use TBDR you subdivide everything anyway.

For 16 interpolated values situation.. Well, I wouldn’t do realtime stuff this in software for obvious reasons. And still, when you do a simple linear interpolation in rasterizer you need to access current value and horizontal step per each component in inner loop(other step is accessed once per scanline), and operation you use for calculating next value is just a simple addition. With barycentric you need to access three values and do a sum of 3 multipliies. I can’t see how THAT can be more efficient. More flexible, more precise, with free perspective correction – yes. But who would choose that over speed in late 90s? :)

fgiesen's avatar
fgiesen permalink
Barycentric is 2 fused-multiply-adds/pixel; that’s what GPUs do, and that’s what you do on CPUs when you have a FMA too.

And this series isn’t about rasterizing on late 90s hardware, it’s about doing it now! :)

noop's avatar
noop permalink
Ok, I inderstand, somewhere in near future, when Intel starts to sell consumer CPUs with FMA support barycentric method will become significally less slow than it is now :)
BTW, thank you for graphics pipeline articles I just discovered, very interesting!

fgiesen's avatar
fgiesen permalink
AMD is already selling them, and PowerPC has had them for two decades now (relevant for console programmers). And of course GPUs have been doing it this way for years, and I’m still a bit in “A Trip Through the Graphics Pipeline” mode when describing things. :) Anyway, this is not entirely as pie-in-the-sky as you make it sound :)

Anyway, don’t worry, the later versions do use per-pixel increments, but I want to make that change late simply because a) it changes results visibly on the test scene (the changes we’ve seen so far don’t) and b) it is less precise. So the idea is to have the corresponding commit late in the git repo, to make sure that reverting it individually is not complicated by surrounding refactorings. :)

TNagel's avatar
TNagel permalink
Are you binning all your scene triangles prior to rasterisation or sending batches down the pipeline?. If you are working with batches would it be better to do setup once per triangle and store the edge constants rather than per bin considering many triangles would span multiple bins?.

Reply
fgiesen's avatar
fgiesen permalink
The code I discuss at the top of this post doesn’t do any binning. The Intel code has first binning then rasterization in separate passes. Doing the setup once trades some computation for memory/cache bandwidth; remember that data has to be both written and read, and they’re separate passes so data is likely to be out of cache by the time you access it. The exact size trade-offs very much depend on the geometry used, but post-setup triangles are likely to be more bandwidth intensive. Purely saving the edge setup computation is probably not going to be worth it; but not having to gather the transformed vertex data might be.

Reply
reima's avatar
reima permalink
For the record: in the first code sample, the stepping code in the inner loop should read “w0 += A12; w1 += A20; w2 += A01;”

Apart from that, I’m really enjoying this series! Thanks for sharing your insights.

Reply
fgiesen's avatar
fgiesen permalink
Oh, indeed. Thanks for pointing it out!

Reply
Andrew's avatar
Andrew permalink
Hello,

I would just like to say that I really like your tutorials. They helps me a lot when working on my own rasterizer. Up until I started reading your tutorials I had been using a scanline rasterizer, but you managed to convert me :D.

However, there is just one thing that I can’t simply wrap my head around. Supposing that you are rasterizing a triangle simply by iterating through the pixels inside its bounding rectangle in 2×2 blocks (no binning, just a simple bounding box traversal). In that case you need a bounding rect of width/height multiple of 2. In case the width/height is odd, we could either subtract one from the minimum extent (minX/minY) of the bounding rect or add 1 to the maximum extent (maxX/maxY). I guess either one would work but special cases arise when the min/max extents reside on the clipping boundaries. In that case the bounding rect would be enlarged outside the clipping area, but because some of those clipped pixels may actually reside inside the triangle, we may actually be writing pixels to invalid memory addresses.

I took a look over the code on Github, but I didn’t manage to see how this problem is treated.

One solution to this would be to add special code inside the ‘for’ loops, but only the thought of that makes me cry. Is there any other way to handle this (in a more graceful manner)?

Oh. And I have one more question regarding alignment. As I understand SSE requires us to work with 16 byte aligned memory addresses. You have mentioned this in your posts a couple of times, but I don’t manage to understand how this should affect triangle rasterization (yeah, I know, I’m a noob ;) ). We use SSE instructions to perform calculations but we don’t use them to write the pixels to the depth/color buffer. So where does alignment come into play? I suppose alignment would also affect how the starting points of the bounding rectangle are calculated.

Thank you!

Reply
fgiesen's avatar
fgiesen permalink
Hi Andrew!

You’re right that in principle, there’s multiple ways to cover a triangle with 2×2 blocks. However, in this case, there’s really only one that makes sense.

In “Depth buffers done quick, part 1“, I explain the storage layout used for the depth buffer. Namely, that the code uses a tiled layout of 2×2 pixel blocks: the depth buffer itself is chopped into tiles of 2×2 pixels that are then stored in usual scan-line order. And the rasterizer always aligns the traversed bounding box to that grid, so that the 2×2 blocks of coverage determined by the rasterizer align with the 2×2 blocks used for depth buffer storage.

The rasterizer in the occlusion culling code does use SSE instructions to read from (and write to) the depth buffer (I go over the rasterizer innards in the “Depth buffer done quick” posts). For each pixel, we store a single floating-point depth value (4 bytes); since we store groups of 2×2 pixels as one block, each block is thus 2x2x4=16 bytes. So if the starting address of the depth buffer is 16-byte aligned, every 2×2 block will be too. It all falls nicely into place.

Regarding clipping/scissoring: you just clip the min/max extents to the size of the depth buffer (or size of your viewport/scissor rect, or size of your tile if you’re rendering in tiles…) before you start rasterizing. The rasterizer still ultimately boils down to looping over pixels and checking whether the triangle covers them. Just don’t even look at pixels that are out of bounds; that’s all there is to it. In general, you do need to start paying attention once the triangles go far enough out of bounds that they might cause overflows in the rasterizer; I talk about this subject a bit in the text, but the Intel Occlusion rendering example just ignores it. What you do in a “proper” implementation is to clip triangles to a region that is small enough to guarantee there are no overflows; this is the “guard band”.

A guard band is essentially free if you’re using this type of rasterizer, and it comes with some nice benefits. For example, it greatly reduces the amount of triangle clipping you need to do for the left/right/top/bottom frustum planes. With a guard band, you still perform the usual rejection tests for triangles based on the actual size of the viewport, but any triangle *clipping* you do is to the guard band rectangle (which is normally significantly larger). Thus, you only need to do real triangle clipping for triangles that are simultaneously overlapping the viewport and extending outside the (much larger) guard band. This is very rare; in practice, almost all real clipping you end up doing with a guard band is against the near plane. It’s pretty nifty. Note that the Intel Occlusion code doesn’t do *any* triangle clipping; it just discards triangles that cross the near plane and hopes that triangles aren’t big enough to cause overflows. :)

Separate issue: what I’ve described so far is enough to handle any viewports, scissor rects etc. that have even X and Y coordinates inside a depth/color buffer with even width and height. The depth/color buffer part is easy: just round up the size to the nearest even multiple (there’s not much else you can do with a tiled 2×2 layout anyway). This means you might end up wasting a bit of space, but such is life. Odd viewport/scissor rect sizes are more annoying. There’s no really nice solution for this; if you need these, you have to support them directly in the rasterizer in some way. Here’s one that’s reasonably easy: every scissor edge that does fall at even coordinates is trivial – you just handle this while computing (and clipping) the bbox. The remaining scissor edges need to be treated in the rasterizer, but it’s not too horrible; you essentially end up rasterizing the scissor edge. Since scissor edges are aligned with x- and y-coordinates, this essentially boils down to computing one x-scissor coverage mask per column and one y-scissor coverage mask per row and ANDing them into the coverage mask you compute per pixel. And of course the “inner” part of your scissor rect (aligned to 2×2 block boundaries) can just use the normal rasterizer anyway. So it can be handled reasonably efficiently, but supporting it does add extra complexity.

Reply
Andrew's avatar
Andrew permalink
Thanks for taking the time to answer my question! I have a little trouble understanding the last paragraph, but I’ll get it eventually.

Max Yankov (@GolerGkA)'s avatar
Max Yankov (@GolerGkA) permalink
> ((w0 | w1 | w2) >= 0)

It looks like an optimisation that compiler would do for you, although I didn’t check it.

Reply
fgiesen's avatar
fgiesen permalink
I did check when I wrote it and none of the compilers I tried (GCC, Clang,VC++) applied this transformation automatically.

Reply
The 8th colored mage's avatar
The 8th colored mage permalink
can you explain the line :if (any(mask >= 0)) on intel?
do you use SSE 4 _mm_test_all_zeros, or you touch each lane of the SSE register? the first one seems constraining, while the second one seems slow,

Reply
fgiesen's avatar
fgiesen permalink
The code’s on Github, you can just look it up! :)

On SSE4.1+ PTEST is indeed preferable, on older cores you just use MOVMSKPS (_mm_movemask_ps).

Reply
thedailyblah's avatar
thedailyblah permalink
Hi, is there a way to interpolate Z-values (integer) as well? Thanks, and great tutorial.

Reply
FordPerfect's avatar
FordPerfect permalink
Two questions about 320×90 pixel tiles (which seems to be just based on a hardcoded screen size):
1. Is there a win in going with very small tiles (e. g. 32×32) to try to stay in L1, and not L2? Even if that would probably mean each thread being responsible for several tiles.
2. Is the size not being power of 2 important (avoiding cache aliasing or something)?
AFAICT, OpenSWR seems to be using 64×64.

Also, regarding “In fact, for any triangle that’s not so large it gets clipped to the screen edges, at least half of the bounding box is going to be empty.”, here’s an additional bit of trivia: average area ratio is 11/36, assuming uniformly distributed vertices. Cute little problem, that.

Reply
eggersa3's avatar
eggersa3 permalink
Love the article. Thank you so much for it! I’m glad its still online.

Reply
Trackbacks & Pingbacks
Depth buffers done quick, part 2 « The ryg blog
Optimizing Software Occlusion Culling – index « The ryg blog
Leave a comment
« Depth buffers done quick, part 1Triangle rasterization in practice »
Recent Posts
Content creator
Oodle 2.9.14 and Intel 13th/14th gen CPUs
UNORM and SNORM to float, hardware edition
MRSSE
Exact UNORM8 to float
BC7 optimal solid-color blocks
Why those particular integer multiplies?
Inserting a 0 bit in the middle of a value
Zero or sign extend
When is a BCn/ASTC endpoints-from-indices solve singular?
Categories
Coding
Compression
Computer Architecture
Demoscene
Graphics Pipeline
Maths
Multimedia
Networking
Papers
Stories
Thoughts
Uncategorized
Archives
July 2025
May 2025
December 2024
November 2024
October 2024
August 2024
October 2023
July 2023
May 2023
March 2023
November 2022
October 2022
September 2022
April 2022
October 2021
August 2021
July 2021
July 2019
April 2019
February 2019
December 2018
September 2018
March 2018
February 2018
January 2018
December 2017
November 2017
September 2017
August 2017
April 2017
October 2016
August 2016
April 2016
March 2016
February 2016
January 2016
December 2015
October 2015
September 2015
July 2015
May 2015
February 2015
December 2014
October 2014
August 2014
July 2014
June 2014
May 2014
March 2014
February 2014
December 2013
November 2013
October 2013
September 2013
August 2013
July 2013
June 2013
May 2013
March 2013
February 2013
January 2013
August 2012
July 2012
June 2012
April 2012
March 2012
February 2012
November 2011
October 2011
September 2011
August 2011
July 2011
May 2011
February 2011
January 2011
December 2010
November 2010
October 2010
September 2010
August 2010
March 2010
December 2009
October 2009
Blog at WordPress.com.