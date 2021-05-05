package hrt.prefab.l3d;

enum abstract HeightMapTextureKind(String) {
	var Albedo = "albedo";
	var Height = "height";
	var Normal = "normal";
	var SplatMap = "splatmap";
}

private class WorldObjects extends h3d.scene.World {

	public var killAlpha = 0.5;

	override function loadMaterialTexture(r:hxd.res.Model, mat:hxd.fmt.hmd.Data.Material, modelName:String):h3d.scene.World.WorldMaterial {
		var m = super.loadMaterialTexture(r, mat, modelName);
		// load real material to apply killAlpha / culling properties
		var wmat = h3d.mat.MaterialSetup.current.createMaterial();
		wmat.name = mat.name;
		wmat.texture = h3d.mat.Texture.fromColor(0); // allow set killAlpha
		wmat.model = r;
		var props = h3d.mat.MaterialSetup.current.loadMaterialProps(wmat);
		if( props == null ) props = wmat.getDefaultModelProps();
		wmat.props = props;
		if( wmat.textureShader != null && wmat.textureShader.killAlpha )
			m.killAlpha = killAlpha;
		if( wmat.mainPass.culling == None )
			m.culling = false;
		return m;
	}

}

class HeightMapShader extends hxsl.Shader {
	static var SRC = {
		@:import h3d.shader.BaseMesh;

		@const var hasHeight : Bool;
		@const var hasNormal : Bool;

		@param var albedo : Sampler2D;
		@param var heightMap : Sampler2D;
		@param var heightMapFrag : Sampler2D;
		@param var normalMap : Sampler2D;
		@param var heightScale : Float;
		@param var heightOffset : Vec2;
		@param var normalScale : Float;
		@param var cellSize : Vec2;
		@const var heightFlipX : Bool;
		@const var heightFlipY : Bool;

		@const var SplatCount : Int;
		@const var AlbedoCount : Int;
		@const var SplatChannels : Int = 4;
		@const var splatLod : Bool;
		@param var albedoSplatScale : Float;
		@param var splats : Array<Sampler2D,SplatCount>;
		@param var albedos : Array<Sampler2D,AlbedoCount>;

		@input var input2 : { uv : Vec2 };

		@const var hasAlbedoProps : Bool;
		@param var albedoGamma : Float;
		@param var albedoProps : Array<Vec4,AlbedoCount>;

		var calculatedUV : Vec2;
		var heightUV : Vec2;

		function getPoint( dx : Float, dy : Float ) : Vec3 {
			var v = vec2(dx,dy);
			return vec3( cellSize * v , heightMapFrag.get(heightUV + heightOffset * v).r * heightScale - relativePosition.z);
		}

		function vertex() {
			calculatedUV = input2.uv;
			heightUV = calculatedUV;
			if( heightFlipX ) heightUV.x = 1 - heightUV.x;
			if( heightFlipY ) heightUV.y = 1 - heightUV.y;
			if( hasHeight ) {
				var z = heightMap.get(heightUV).x * heightScale;
				relativePosition.z = z;
			}
		}

		function setNormal(n:Vec3) {
			transformedNormal = (n.normalize() * global.modelView.mat3()).normalize();
		}

		function getAlbedo( color : Vec4 ) : Vec4 {
			if( albedoGamma != 1 )
				color = color.pow(albedoGamma.xxxx);
			return color;
		}

		function splat( color : Vec4, index : Int, amount : Float ) : Vec4 {
			if( index >= AlbedoCount || amount <= 0 )
				return color;
			else if( hasAlbedoProps ) {
				var p = albedoProps[index];
				return color + getAlbedo(albedos[index].get(calculatedUV * p.w)) * vec4(p.rgb,1) * amount;
			} else
				return color + getAlbedo(albedos[index].get(calculatedUV * albedoSplatScale)) * amount;
		}

		function __init__fragment() {
			if( hasNormal ) {
				var n = unpackNormal(normalMap.get(calculatedUV));
				n = n.normalize();
				n.xy *= normalScale;
				setNormal(n);
			} else {
				var px0 = getPoint(-1,0);
				var py0 = getPoint(0, -1);
				var px1 = getPoint(1, 0);
				var py1 = getPoint(0, 1);
				var n = px1.cross(py1) + py1.cross(px0) + px0.cross(py0) + py0.cross(px1);
				n.xy *= normalScale;
				setNormal(n);
			}
			if( SplatCount > 0 ) {
				var color = vec4(0.);
				@unroll for( i in 0...SplatCount ) {
					var s = splatLod ? splats[i].getLod(calculatedUV,0) : splats[i].get(calculatedUV);
					color = splat(color, i*SplatChannels, s.r);
					if( SplatChannels > 1 )
						color = splat( color, i*SplatChannels+1, s.g);
					if( SplatChannels > 2 )
						color = splat( color, i*SplatChannels+2, s.b);
					if( SplatChannels > 3 )
						color = splat( color, i*SplatChannels+3, s.a);
				}
				color.a = 1;
				pixelColor = color;
			} else {
				pixelColor = getAlbedo(albedo.get(calculatedUV));
			}
		}

	};
}

class HeightMapTile {

	public var tx(default,null) : Int;
	public var ty(default,null) : Int;
	public var bounds(default, null) : h3d.col.Bounds;
	public var root(default,null) : h3d.scene.Mesh;

	var hmap : HeightMap;
	var height : hxd.Pixels;

	public function new(hmap, tx, ty) {
		this.hmap = hmap;
		this.tx = tx;
		this.ty = ty;
		bounds = h3d.col.Bounds.fromValues(tx * hmap.size, ty * hmap.size, hmap.minZ, hmap.size, hmap.size, hmap.maxZ - hmap.minZ);
	}

	public function remove() {
		if( root != null ) {
			root.remove();
			root = null;
		}
	}

	public function isEmpty() {
		if( tx == 0 && ty == 0 && hmap.sizeX == 0 && hmap.sizeY == 0 && !hmap.autoSize )
			return false;
		getHeight();
		return height.width == 1;
	}

	public function getHeight() {
		if( height == null ) {
			for( t in hmap.textures )
				if( t.kind == Height && t.enable && t.path != null ) {
					var path = resolveTexturePath(t.path);
					if( path == t.path && (tx != 0 || ty != 0) ) continue;
					height = try hxd.res.Loader.currentInstance.load(path).toImage().getPixels() catch( e : hxd.res.NotFound )
					#if editor try hxd.res.Any.fromBytes(path, sys.io.File.getBytes(hide.Ide.inst.getPath(path))).toImage().getPixels() catch( e : Dynamic ) #end
					null;
					break;
				}
			if( height == null ) height = hxd.Pixels.alloc(1, 1, R32F);
			height.convert(R32F);
		}
		return height;
	}

	@:access(hrt.prefab.l3d.HeightMapMesh)
	public function create(mesh:HeightMapMesh) {
		if( root != null ) throw "assert";
		root = new h3d.scene.Mesh(mesh.grid);
		root.material.mainPass.setPassName("terrain");
		root.x = hmap.size * tx;
		root.y = hmap.size * ty;

		inline function getTextures(k) return hmap.getTextures(k,tx,ty);
		var htex = getTextures(Height)[0];
		var splat = getTextures(SplatMap);
		var albedo = getTextures(Albedo);
		var normal = getTextures(Normal)[0];

		var shader = root.material.mainPass.addShader(new HeightMapShader());
		shader.albedo = albedo[0];
		if( shader.albedo == null )
			shader.albedo = h3d.mat.Texture.fromColor(0x808080);
		shader.hasHeight = htex != null;
		shader.heightMap = shader.heightMapFrag = htex;
		shader.hasNormal = normal != null;
		shader.normalMap = normal;
		shader.heightScale = hmap.getHScale();
		shader.normalScale = hmap.heightScale * hmap.normalScale;
		var qsize = Math.pow(2,4 - hmap.quality);
		shader.cellSize.set(mesh.grid.cellWidth / qsize,mesh.grid.cellHeight / qsize);
		shader.heightFlipX = hmap.heightFlipX;
		shader.heightFlipY = hmap.heightFlipY;
		if( htex != null ) shader.heightOffset.set( (hmap.heightFlipX ? -1 : 1) / htex.width, (hmap.heightFlipY ? -1 : 1) / htex.height);

		var channels = hmap.splatChannels;
		var scount = hxd.Math.imin(splat.length, Math.ceil(albedo.length/channels));
		shader.SplatCount = scount;
		shader.AlbedoCount = albedo.length;
		shader.SplatChannels = channels;
		shader.albedoSplatScale = hmap.albedoSplatScale;
		shader.albedoGamma = hmap.albedoGamma;
		shader.splatLod = hmap.splatLod;
		shader.splats = [for( i in 0...scount ) splat[i]];
		shader.albedos = [for( i in 0...albedo.length ) { var t = albedo[i]; t.wrap = Repeat; t; }];
		if( scount > 0 ) shader.albedo = null;

		shader.albedoProps = hmap.getAlbedoProps();
		shader.hasAlbedoProps = shader.albedoProps.length > 0;

		addObjects(mesh);
	}

	function addObjects( mesh : HeightMapMesh ) {
		if( hmap.objects == null ) return;
		var model = null;
		decodeObjects(function(name) {
			model = mesh.resolveAssetModel(name);
			return model != null;
		},function(pos) {
			if( !mesh.isAssetFiltered(model,pos) )
				@:privateAccess mesh.world.addTransform(model, pos);
		});
	}

	public inline function decodeObjects( onModel : String -> Bool, onAdd : h3d.Matrix -> Void ) {
		var data = hmap.storedCtx.shared.loadBytes(hmap.resolveTexturePath(hmap.objects.file,tx,ty));
		if( data == null ) return;
		var xml = new haxe.xml.Access(Xml.parse(data.toString()).firstElement());
		var terrainWidth = Std.parseFloat(xml.node.Surface.att.Width);
		var scale = hmap.size / terrainWidth;
		var localScale = hmap.objects.scale * scale;
		var posX = tx * hmap.size;
		var posY = ty * hmap.size;

		var xMax = 0., yMax = 0.;

		for( layer in xml.node.Objects.node.Layers.nodes.Layer ) {
			for( obj in layer.nodes.Object ) {
				if( !onModel(obj.att.MeshAssetFileName) ) continue;
				var data = haxe.crypto.Base64.decode(obj.node.Data.innerData);
				for( i in 0...Std.int(data.length/40) ) {
					var p = i * 40;
					var x = data.getFloat(p); p += 4;
					p += 4;
					var y = terrainWidth - data.getFloat(p); p += 4;
					if( x > xMax ) xMax = x;
					if( y > yMax ) yMax = y;

					x *= scale;
					y *= scale;

					var scW = data.getFloat(p); p += 4;
					var scH = data.getFloat(p); p += 4;
					var rotX = data.getFloat(p); p += 4;
					var rotY = data.getFloat(p); p += 4;
					var rotZ = data.getFloat(p); p += 4;
					p += 4; // ???
					var tint = data.getInt32(p);
					tint = tint & 0xFFFFFF;
					tint = ((tint & 0xFF) << 16) | (tint & 0xFF00) | (tint >> 16);

					var mat = new h3d.Matrix();
					mat.initScale(scW * localScale, scW * localScale, scH * localScale);
					mat.rotate(rotX * Math.PI * 2, rotZ * Math.PI * 2, rotY * Math.PI * 2);
					mat.tx = x + posX;
					mat.ty = y + posY;
					mat.tz = hmap.getZ(mat.tx, mat.ty);

					onAdd(mat);
				}
			}
		}
	}

	inline function resolveTexturePath( path : String ) {
		return hmap.resolveTexturePath(path, tx, ty);
	}

}

class HeightMapMesh extends h3d.scene.Object {

	var hmap : HeightMap;
	var grid : HeightGrid;
	var world : WorldObjects;
	var modelCache : Map<String, h3d.scene.World.WorldModel> = new Map();
	var nullModel = new h3d.scene.World.WorldModel(null);

	public function new(hmap, ?parent) {
		super(parent);
		this.hmap = hmap;
	}

	override function sync(ctx:h3d.scene.RenderContext) {
		super.sync(ctx);

		var r = h3d.col.Ray.fromPoints(ctx.camera.unproject(0,0,0).toPoint(), ctx.camera.unproject(0,0,1).toPoint());
		var pt0 = r.intersect(h3d.col.Plane.Z(0));
		var x0 = Math.round(pt0.x / hmap.size);
		var y0 = Math.round(pt0.y / hmap.size);

		// spiral for-loop
		var dx = 0, dy = 0, d = 1, m = 1, out = 0;
		while( true ) {
			var xyOut = true;
			while( m > 2 * dx * d ) {
				if( checkTile(ctx,dx+x0,dy+y0) ) xyOut = false;
				dx += d;
			}
			while( m > 2 * dy * d ) {
				if( checkTile(ctx,dx+x0,dy+y0) ) xyOut = false;
				dy += d;
			}
			if( xyOut ) {
				out++;
				if( out == 2 ) break;
			} else
				out = 0;
			d = -d;
			m++;
		}
		if( world != null )
			world.done();
	}

	public dynamic function onTileReady( t : HeightMapTile ) {
	}

	public dynamic function isAssetFiltered( obj : h3d.scene.World.WorldModel, pos : h3d.Matrix ) {
		return false;
	}

	function checkTile( ctx : h3d.scene.RenderContext, x : Int, y : Int ) {
		var t = hmap.getTile(x,y);
		if( !ctx.camera.frustum.hasBounds(t.bounds) || t.isEmpty() ) {
			if( t.root != null ) t.root.visible = false;
			return x >= 0 && y >= 0 && x < hmap.sizeX && y < hmap.sizeY;
		}
		if( t.root != null )
			t.root.visible = true;
		else
			initTile(t);
		return true;
	}

	public function initTile( t : HeightMapTile ) {
		if( t.root != null ) return;
		t.create(this);
		addChild(t.root);
		onTileReady(t);
	}

	public function init() {
		var htex = hmap.getTextures(Height, 0, 0)[0];
		var size = hmap.size;
		var width = htex == null ? Std.int(size) : Math.ceil(htex.width * hmap.heightPrecision);
		var height = htex == null ? Std.int(size) : Math.ceil(htex.height * hmap.heightPrecision);
		width >>= (4 - hmap.quality);
		height >>= (4 - hmap.quality);
		if( width < 4 ) width = 4;
		if( height < 4 ) height = 4;
		var cw = size/width, ch = size/height;
		if( grid == null || grid.width != width || grid.height != height || grid.cellWidth != cw || grid.cellHeight != ch ) {
			grid = new HeightGrid(width,height,cw,ch);
			grid.zMin = hmap.minZ;
			grid.zMax = hmap.maxZ;
			grid.addUVs();
			grid.addNormals();
		}
		modelCache = new Map();
		if( world != null ) {
			world.dispose();
			world = null;
		}
		if( hmap.objects != null ) {
			world = new WorldObjects(Std.int(size),this);
			world.enableNormalMaps = true;
			world.enableSpecular = true;
			world.killAlpha = hmap.objects.killAlpha;
		}
	}

	public function resolveAssetModel( name : String ) {
		var m = modelCache.get(name);
		if( m != null ) return m == nullModel ? null : m;
		var res = hmap.resolveAssetModel(name);
		if( res == null ) {
			modelCache.set(name, nullModel);
			return null;
		}
		m = world.loadModel(res);
		modelCache.set(name, m);
		return m;
	}


}

@:allow(hrt.prefab.l3d)
class HeightMap extends Object3D {

	var tilesCache : Map<Int,HeightMapTile> = new Map();
	var emptyTile : HeightMapTile;
	@:c var textures : Array<{ path : String, kind : HeightMapTextureKind, enable : Bool, ?props : { color : Int, scale : Float } }> = [];
	@:s var size = 128.;
	@:s var heightScale = 0.2;
	@:s var heightFlipX = false;
	@:s var heightFlipY = false;
	@:s var normalScale = 1.;
	@:s var heightPrecision = 1.;
	@:s var minZ = -10;
	@:s var maxZ = 30;
	@:s public var quality = 4;
	@:s var objects : {
		var file : String;
		var assetsPath : String;
		var scale : Float;
		var killAlpha : Float;
	};
	@:s var sizeX = 0;
	@:s var sizeY = 0;
	@:s var autoSize = false;
	@:s var splatChannels = 4;
	@:s var albedoSplatScale = 1.;
	@:s var albedoGamma = 1.;
	@:s var albedoColorGamma = 1.;
	@:s var splatLod = false;

	// todo : instead of storing the context, we should find a way to have a texture loader
	var storedCtx : hrt.prefab.Context;
	#if editor
	var missingObjects : Map<String,Bool> = new Map();
	var checkModels : Bool = true;
	#end
	var albedoProps : Array<h3d.Vector>;

	override function save():{} {
		var o : Dynamic = super.save();
		o.textures = [for( t in textures ) {
			var v : Dynamic = { path : t.path, kind : t.kind };
			if( !t.enable ) v.enable = false;
			if( t.props != null ) v.props = t.props;
			v;
		}];
		return o;
	}

	override function load(obj:Dynamic) {
		super.load(obj);
		textures = [for( o in (obj.textures:Array<Dynamic>) ) { path : o.path, kind : o.kind, enable : o.enable == null ? true : o.enable, props : o.props }];
	}

	function getAlbedoProps() {
		if( albedoProps != null )
			return albedoProps;
		var hasProps = false;
		for( t in textures )
			if( t.kind == Albedo && t.props != null )
				hasProps = true;
		if( !hasProps ) {
			albedoProps = [];
			return albedoProps;
		}
		albedoProps = [for( t in textures ) if( t.kind == Albedo ) t.props == null ? new h3d.Vector(1,1,1,albedoSplatScale) : {
			var v = h3d.Vector.fromColor(t.props.color);
			v.r = Math.pow(v.r,albedoColorGamma);
			v.g = Math.pow(v.g,albedoColorGamma);
			v.b = Math.pow(v.b,albedoColorGamma);
			v.a = t.props.scale * albedoSplatScale;
			v;
		}];
		return albedoProps;
	}

	public function getZ( x : Float, y : Float ) : Null<Float> {
		var rx = x / size;
		var ry = y / size;
		var tx = Math.floor(rx);
		var ty = Math.floor(ry);
		var curMap = getTile(tx, ty).getHeight();
		if( curMap == null )
			return null;
		var w = curMap.width;
		var ix = Std.int( (rx - tx) * w );
		var iy = Std.int( (ry - ty) * w );
		var h = curMap.bytes.getFloat((ix+iy*w) << 2);
		h *= getHScale();
		return h;
	}

	override function localRayIntersection(ctx:Context, ray:h3d.col.Ray):Float {
		if( ray.lz > 0 )
			return -1; // only from top
		if( ray.lx == 0 && ray.ly == 0 ) {
			var z = getZ(ray.px, ray.py);
			if( z == null || z > ray.pz ) return -1;
			return ray.pz - z;
		}
		var dist = 0.;
		if( ray.pz > maxZ ) {
			if( ray.lz == 0 )
				return -1;
			dist = (maxZ - ray.pz) / ray.lz;
		}
		var pt = ray.getPoint(dist);
		if( pt.z < minZ )
			return -1;

		var prim = @:privateAccess cast(ctx.local3d, HeightMapMesh).grid;
		var m = hxd.Math.min(prim.cellWidth, prim.cellHeight) * 0.5;
		var curX = -1, curY = -1, curMap = null, offX = 0., offY = 0., cw = 0., ch = 0.;
		var prevH = pt.z;
		var hscale = getHScale();

		while( true ) {
			pt.x += ray.lx * m;
			pt.y += ray.ly * m;
			pt.z += ray.lz * m;
			if( pt.z < minZ )
				return -1;
			var px = Math.floor(pt.x / size);
			var py = Math.floor(pt.y / size);
			if( px != curX || py != curY ) {
				curX = px;
				curY = py;
				offX = -px * size;
				offY = -py * size;
				var t = getTile(px, py);
				curMap = t.getHeight();
				if( t.isEmpty() )
					curMap = null;
				else {
					cw = curMap.width / size;
					ch = curMap.height / size;
				}
			}
			if( curMap == null )
				continue;
			var ix = Std.int((pt.x + offX)*cw);
			var iy = Std.int((pt.y + offY)*ch);
			var h = curMap.bytes.getFloat( (ix + iy * curMap.width) << 2 );
			h *= hscale;
			if( pt.z < h ) {
				// todo : fix interpolation using getZ dichotomy
				var k = 1 - (prevH - (pt.z - ray.lz * m)) / (ray.lz * m - (h - prevH));
				pt.x -= k * ray.lx * m;
				pt.y -= k * ray.ly * m;
				pt.z -= k * ray.lz * m;
				return pt.sub(ray.getPos()).length();
			}
			prevH = h;
		}
		return -1;
	}

	function getTile( x : Int, y : Int ) {
		if( (sizeX > 0 && sizeY > 0 && (x < 0 || y < 0 || x >= sizeX || y >= sizeY)) || (sizeX == 0 && sizeY == 0 && (x != 0 || y != 0) && !autoSize) ) {
			if( emptyTile == null )
				emptyTile = new HeightMapTile(this, -1, -1);
			return emptyTile;
		}
		var id = x + y * 65535;
		var t = tilesCache[id];
		if( t != null )
			return t;
		t = new HeightMapTile(this, x, y);
		tilesCache[id] = t;
		return t;
	}

	function resolveTexturePath( path : String, tx : Int, ty : Int ) {
		if( tx != 0 || ty != 0 ) {
			var parts = path.split("0");
			switch( parts.length ) {
			case 2:
				path = tx + parts[0] + ty + parts[1];
			case 3:
				path = parts[0] + tx + parts[1] + ty + parts[2];
			default:
				// pattern not recognized - should contain 2 zeroes
			}
		}
		return path;
	}

	function resolveAssetModel( name : String ) : hxd.res.Model {
		var path = objects.assetsPath + "/" + name;
		if( objects.assetsPath.indexOf("$") >= 0 ) {
			path = objects.assetsPath;
			path = path.split("$NAME").join(name);
			var base = name;
			while( true ) {
				var c = base.charCodeAt(base.length-1);
				if( c == '_'.code || (c >= '0'.code && c <= '9'.code) )
					base = base.substr(0,-1);
				else
					break;
			}
			path = path.split("$BASE").join(base);
		}
		var res = try hxd.res.Loader.currentInstance.load(path + ".FBX").toModel() catch( e : hxd.res.NotFound )
			try hxd.res.Loader.currentInstance.load(path + ".fbx").toModel() catch( e : hxd.res.NotFound ) {
				#if editor
				if( checkModels && !missingObjects.exists(path) ) {
					missingObjects.set(path, true);
					hide.Ide.inst.error(path+".fbx is missing");
				}
				#end
				return null;
			};
		return res;
	}

	function getTextures( k : HeightMapTextureKind, tx : Int, ty : Int ) {
		var tl = [];
		for( t in textures )
			if( t.kind == k && t.path != null && t.enable ) {
				var path = resolveTexturePath(t.path,tx,ty);
				tl.push(loadTexture(path));
			}
		return tl;
	}

	function loadTexture( path : String ) {
		return storedCtx.loadTexture(path);
	}

	override function makeInstance(ctx:Context):Context {
		ctx = ctx.clone(this);
		var mesh = new HeightMapMesh(this, ctx.local3d);
		ctx.local3d = mesh;
		ctx.local3d.name = name;
		storedCtx = ctx;
		updateInstance(ctx);
		return ctx;
	}

	override function updateInstance( ctx : Context, ?propName : String ) {

		#if editor
		if( (propName == "albedoSplatScale" || propName == "albedoColorGamma") && albedoProps != null ) {
			updateAlbedoProps();
			return;
		}
		#end

		albedoProps = null;
		super.updateInstance(ctx, propName);

		var mesh = cast(ctx.local3d, HeightMapMesh);
		if( propName == "killAlpha" ) {
			var world = @:privateAccess mesh.world;
			if( world != null ) {
				for( c in @:privateAccess world.allChunks )
					for( m in c.root )
						m.toMesh().material.textureShader.killAlphaThreshold = objects.killAlpha;
			}
			return;
		}

		for( t in tilesCache )
			t.remove();
		tilesCache = new Map();
		mesh.init();
	}

	function getHScale() {
		return heightScale * size * 0.1;
	}

	#if editor

	override function getHideProps() : HideProps {
		return { icon : "industry", name : "HeightMap", isGround : true };
	}

	function updateAlbedoProps() {
		var prev = albedoProps;
		while( prev.length > 0 ) prev.pop();
		albedoProps = null;
		for( x in getAlbedoProps() )
			prev.push(x);
		albedoProps = prev;
	}

	override function edit(ectx:EditContext) {
		super.edit(ectx);
		var ctx = ectx.getContext(this);
		var props = new hide.Element('
		<div>
			<div class="group" name="View">
			<dl>
				<dt>Size</dt><dd><input type="range" min="0" max="1000" value="128" field="size"/></dd>
				<dt>Height Scale</dt><dd><input type="range" min="0" max="1" field="heightScale"/></dd>
				<dt>Height Precision</dt><dd><input type="range" min="0.1" max="1" field="heightPrecision"/></dd>
				<dt>Height Flip</dt><dd>
					<label><input type="checkbox"field="heightFlipX"/> X</label>
					<label><input type="checkbox"field="heightFlipY"/> Y</label>
				</dd>
				<dt>Normal Scale</dt><dd><input type="range" min="0" max="2" field="normalScale"/></dd>
				<dt>MinZ</dt><dd><input type="range" min="-1000" max="0" field="minZ"/></dd>
				<dt>MaxZ</dt><dd><input type="range" min="0" max="1000" field="maxZ"/></dd>
				<dt>Quality</dt><dd><input type="range" min="0" max="4" field="quality" step="1"/></dd>
				<dt>Splat</dt><dd>
					Channels <input type="number" style="width:50px" field="splatChannels"/>
					<label><input type="checkbox" field="splatLod"/> Lod</label>
				</dd>
				<dt>Splat Scale</dt><dd><input type="range" field="albedoSplatScale"/>
				<dt>Gamma</dt><dd><input type="range" min="0" max="4" field="albedoGamma"/></dd>
				<dt>Gamma Color</dt><dd><input type="range" min="0" max="4" field="albedoColorGamma"/></dd>
				<dt>Fixed Size</dt><dd><input type="number" style="width:50px" field="sizeX"/><input type="number" style="width:50px" field="sizeY"/> <label><input type="checkBox" field="autoSize"> Auto</label></dd>
			</dl>
			</div>
			<div class="group" name="Textures">
				<ul id="tex"></ul>
			</div>
			<div class="group" name="Objects">
			</div>
		</div>
		');

		var list = props.find("ul#tex");
		ectx.properties.add(props,this, (_) -> updateInstance(ctx));
		for( tex in textures ) {
			var prevTex = tex.path;
			var e = new hide.Element('<li style="position:relative">
				<input type="checkbox" field="enable"/>
				<input type="texturepath" style="width:160px" field="path"/>
				<select field="kind" style="width:70px">
					<option value="albedo">Albedo
					<option value="height">Height
					<option value="normal">Normal
					<option value="splatmap">SplatMap
					<option value="albedoProps">Albedo + Props
					<option value="delete">-- Delete --
				</select>
				<a href="#" class="up">🡅</a>
				<a href="#" class="down">🡇</a>
			</li>
			');
			e.find(".up").click(function(_) {
				var index = textures.indexOf(tex);
				if( index <= 0 ) return;
				textures.remove(tex);
				textures.insert(index-1, tex);
				ectx.rebuildProperties();
				updateInstance(ctx);
			});
			e.find(".down").click(function(_) {
				var index = textures.indexOf(tex);
				textures.remove(tex);
				textures.insert(index+1, tex);
				ectx.rebuildProperties();
				updateInstance(ctx);
			});
			e.appendTo(list);
			ectx.properties.build(e, tex, (pname) -> {
				if( ""+tex.kind == "albedoProps" ) {
					tex.kind = Albedo;
					if( tex.props == null ) {
						tex.props = {
							color : 0xFFFFFF,
							scale : 1,
						};
						ectx.rebuildProperties();
					}
				} else if( tex.props != null ) {
					tex.props = null;
					ectx.rebuildProperties();
				}
				if( tex.path != prevTex ) {
					tex.enable = true; // enable on change texture !
					prevTex = tex.path;
				}
				if( ""+tex.kind == "delete" ) {
					textures.remove(tex);
					ectx.rebuildProperties();
				}
				updateInstance(ctx, pname);
			});
			if( tex.props != null ) {
				var e = new hide.Element('<li style="position:relative">
					Scale <input type="range" min="0" max="10" field="scale"/>
					<input type="color" field="color"/>
 				</li>');
				e.appendTo(list);
				ectx.properties.build(e, tex.props, (pname) -> updateAlbedoProps());
			}
		}
		var add = new hide.Element('<li><p><a href="#">[+]</a></p></li>');
		add.appendTo(list);
		add.find("a").click(function(_) {
			textures.push({ path : null, kind : Albedo, enable: true });
			ectx.rebuildProperties();
		});

		var objs = props.find("[name=Objects] .content");
		if( objects == null ) {
			var e = new hide.Element('
			<dl>
				<dt></dt><dd><a class="button" href="#">Add</a></dd>
			</dl>
			');
			e.appendTo(objs).find("a.button").click(function(_) {
				objects = {
					file : "",
					assetsPath : "",
					scale : 1,
					killAlpha : 0.5,
				};
				checkModels = false;
				ectx.rebuildProperties();
				checkModels = true;
			});
		} else {
			var e = new hide.Element('
			<dl>
				<dt>File</dt><dd><input type="fileselect" field="file"/></dd>
				<dt>Assets Path</dt><dd><input field="assetsPath"/></dd>
				<dt>Scale</dt><dd><input type="range" min="0" max="2" field="scale"/></dd>
				<dt>KillAlpha</dt><dd><input type="range" min="0" max="1" field="killAlpha"/></dd>
				<dt></dt><dd><a class="button" href="#">Remove</a></dd>
			</dl>
			');
			ectx.properties.build(e, objects, function(pname) {
				checkModels = false;
				updateInstance(ctx,pname);
				checkModels = true;
			});
			e.appendTo(objs).find("a.button").click(function(_) {
				objects = null;
				ectx.rebuildProperties();
			});
		}
	}
	#end

	static var _ = Library.register("heightmap", HeightMap);

}


class HeightGrid extends h3d.prim.MeshPrimitive {

	/**
		The number of cells in width
	**/
	public var width (default, null) : Int;

	/**
		The number of cells in height
	**/
	public var height (default, null)  : Int;

	/**
		The width of a cell
	**/
	public var cellWidth (default, null) : Float;

	/**
		The height of a cell
	**/
	public var cellHeight (default, null)  : Float;

	/**
	 *  Minimal Z value, used for reporting bounds.
	 **/
	public var zMin = 0.;

	/**
	 *  Maximal Z value, used for reporting bounds.
	 **/
	public var zMax = 0.;

	var hasNormals : Bool;
	var hasUVs : Bool;

	public function new( width : Int, height : Int, cellWidth = 1., cellHeight = 1. ) {
		this.width = width;
		this.height = height;
		this.cellWidth = cellWidth;
		this.cellHeight = cellHeight;
	}

	public function addNormals() {
		hasNormals = true;
	}

	public function addUVs() {
		hasUVs = true;
	}

	override function getBounds():h3d.col.Bounds {
		return h3d.col.Bounds.fromValues(0,0,zMin,width*cellWidth,height*cellHeight,zMax-zMin);
	}

	override function alloc(engine:h3d.Engine) {
		dispose();
		var size = 3;
		var names = ["position"];
		var positions = [0];
		if( hasNormals ) {
			names.push("normal");
			positions.push(size);
			size += 3;
		}
		if( hasUVs ) {
			names.push("uv");
			positions.push(size);
			size += 2;
		}

		var buf = new hxd.FloatBuffer((width + 1) * (height +  1) * size);
		var p = 0;
		for( y in 0...height + 1 )
			for( x in 0...width + 1 ) {
				buf[p++] = x * cellWidth;
				buf[p++] = y * cellHeight;
				buf[p++] = 0;
				if( hasNormals ) {
					buf[p++] = 0;
					buf[p++] = 0;
					buf[p++] = 1;
				}
				if( hasUVs ) {
					buf[p++] = x / width;
					buf[p++] = y / height;
				}
			}
		var flags : Array<h3d.Buffer.BufferFlag> = [LargeBuffer];
		buffer = h3d.Buffer.ofFloats(buf, size, flags);

		for( i in 0...names.length )
			addBuffer(names[i], buffer, positions[i]);

		indexes = new h3d.Indexes(width * height * 6, true);
		var b = haxe.io.Bytes.alloc(indexes.count * 4);
		var p = 0;
		for( y in 0...height )
			for( x in 0...width ) {
				var s = x + y * (width + 1);
				b.setInt32(p++ << 2, s);
				b.setInt32(p++ << 2, s + 1);
				b.setInt32(p++ << 2, s + width + 1);
				b.setInt32(p++ << 2, s + 1);
				b.setInt32(p++ << 2, s + width + 2);
				b.setInt32(p++ << 2, s + width + 1);
			}
		indexes.uploadBytes(b,0,indexes.count);
	}

}
