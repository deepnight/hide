package hrt.prefab.fx.gpuemitter;

class BaseSpawn extends ComputeUtils {
	static var SRC = {
		@param var batchBuffer : RWPartialBuffer<{
			modelView : Mat4, 
		}>;
		@param var particleBuffer : RWBuffer<Vec4>;

		@const var SPEED_NORMAL : Bool;
		@param var minLifeTime : Float;
		@param var maxLifeTime : Float;
		@param var minStartSpeed : Float;
		@param var maxStartSpeed : Float;
		@param var absPos : Mat4;

		var lifeTime : Float;
		var modelView : Mat4;
		var relativeTransform : Mat4;
		var emitNormal : Vec3;
		function __init__() {
			emitNormal = vec3(0.0, 0.0, 1.0);
			lifeTime = mix(minLifeTime, maxLifeTime, (global.time + computeVar.globalInvocation.x * 0.5123789) % 1.0);
			relativeTransform = translationMatrix(vec3(0.0));
			modelView = relativeTransform * absPos;
		}

		function main() {
			var idx = computeVar.globalInvocation.x;
			if ( particleBuffer[idx].w < 1e-7 ) {
				batchBuffer[idx].modelView = modelView;
				var s = vec3(0.0, 0.0, 1.0);
				if ( SPEED_NORMAL )
					s = emitNormal;
				particleBuffer[idx].xyz = s * maxStartSpeed;
				particleBuffer[idx].w = lifeTime;
			}
		}
	}
}