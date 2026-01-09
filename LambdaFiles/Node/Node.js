exports.handler = async (event) => {
    // TODO: Implement your logic here
    const response = {
        statusCode: 200,
        body: JSON.stringify('Hello from CloudMan (Node.js)!'),
    };
    return response;
};